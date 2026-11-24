# Verso's Add Photos icon: a photo (a frame with a hill and a sun) with a plus at its corner, so adding photos to an
# album or a link is told apart from the + that adds people, and from Add to Album, which adds the photos selected. On
# a 16-pixel grid in one solid colour (GTK recolours it), as Verso's other icons. Needs Shapely. Writes
# verso-add-photos-symbolic.svg into the folder given:
# python3 linux/packaging/icons/sources/add-photos.py linux/packaging/icons
import sys, pathlib
from shapely.geometry import Point, Polygon, MultiPolygon, box
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

def rounded(l, t, r, b, rad): return box(l + rad, t + rad, r - rad, b - rad).buffer(rad, 32)

frame_outer = rounded(0.8, 1.6, 12.6, 12.4, 2.0)
frame = frame_outer.difference(frame_outer.buffer(-1.3, 32))
inside = frame_outer.buffer(-1.3, 32)
hill = Polygon([(2.1, 11.1), (5.4, 6.6), (7.6, 9.2), (8.9, 7.7), (11.6, 11.1)]).intersection(inside)
sun = Point(8.9, 4.7).buffer(1.15, 32)
photo = unary_union([frame, hill, sun])
# The plus at the corner, the photo cut clear of it.
plus = unary_union([box(12.25 - 0.8, 9.0, 12.25 + 0.8, 15.5), box(9.0, 12.25 - 0.8, 15.5, 12.25 + 0.8)])
icon = unary_union([photo.difference(plus.buffer(1.0, 32, join_style=2)), plus])
(out / "verso-add-photos-symbolic.svg").write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n'
    "  <!-- Add Photos (an album's or a link's): a photo with a plus at its corner, apart from the + that adds people and\n"
    "       Add to Album. -->\n"
    f'  <path fill="#000000" fill-rule="evenodd" d="{path(icon)}"/>\n</svg>\n')
print("ok")
