# Verso's favorite icon, a heart as on the Mac, filled for a favorite and outlined for not, so a star is left to mean
# a rating (one to five), never a favorite. On a 16-pixel grid in one solid colour (GTK recolours it), as Verso's other
# icons. Needs Shapely. Writes verso-heart-symbolic.svg and verso-heart-outline-symbolic.svg into the folder given:
# python3 linux/packaging/icons/sources/heart.py linux/packaging/icons
import math, sys, pathlib
from shapely.geometry import Point, Polygon, MultiPolygon
from shapely.ops import unary_union

out = pathlib.Path(sys.argv[1])

def f(v): return f"{v:.3f}".rstrip("0").rstrip(".")

def path(geom):
    polys = list(geom.geoms) if isinstance(geom, MultiPolygon) else [geom]
    rings = []
    for poly in polys:
        for ring in [poly.exterior, *poly.interiors]:
            rings.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in list(ring.coords)[:-1]) + " Z")
    return " ".join(rings)

def svg(geom, note):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n  <!-- {note} -->\n'
            f'  <path fill="#000000" fill-rule="evenodd" d="{path(geom)}"/>\n</svg>\n')

def tangent(cx, cy, r, px, py, outer):
    """Where a line from (px, py) touches the circle, on its outer side: the leftmost touch for -1, rightmost for 1."""
    dx, dy = cx - px, cy - py
    d = math.hypot(dx, dy)
    base, spread, t = math.atan2(dy, dx), math.asin(r / d), math.sqrt(d * d - r * r)
    touches = [(px + t * math.cos(base + s * spread), py + t * math.sin(base + s * spread)) for s in (-1, 1)]
    return min(touches, key=lambda point: outer * -point[0])

r, cy, gap = 3.75, 5.9, 2.75
left, right, tip = (8 - gap, cy), (8 + gap, cy), (8.0, 14.7)
lt = tangent(*left, r, *tip, -1)
rt = tangent(*right, r, *tip, 1)
body = Polygon([tip, lt, left, right, rt])
assert body.is_valid
heart = unary_union([Point(*left).buffer(r, 128), Point(*right).buffer(r, 128), body])
# The tip and the cleft a little round, as the globe's lines are.
heart = heart.buffer(-0.45, 64).buffer(0.45, 64).buffer(0.3, 64).buffer(-0.3, 64)
outline = heart.difference(heart.buffer(-1.3, 64))
(out / "verso-heart-symbolic.svg").write_text(svg(heart, "A favorite (the sidebar, a photo's badge, the viewer, the selection, a person): a heart, filled, as on the Mac; a star means a rating."))
(out / "verso-heart-outline-symbolic.svg").write_text(svg(outline, "Not a favorite yet, where a heart turns it on: the heart's outline."))
print("ok")
