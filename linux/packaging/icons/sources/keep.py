# Verso's Keep icon for a memory, a bookmark ribbon, filled once kept and outlined before: keeping a memory saves it
# from Immich's 30-day cleanup, and a bookmark is how a thing to keep is marked. Not a star, which means a rating, nor a
# heart, a favorite. On a 16-pixel grid in one solid colour (GTK recolours it), as Verso's other icons. Needs Shapely.
# Writes verso-keep-symbolic.svg and verso-keep-outline-symbolic.svg into the folder given:
# python3 linux/packaging/icons/sources/keep.py linux/packaging/icons
import sys, pathlib
from shapely.geometry import Polygon, MultiPolygon, box

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

# A ribbon with a notch cut up into its foot, its corners a little round, as the heart's.
ribbon = Polygon([(3.2, 1.0), (12.8, 1.0), (12.8, 15.2), (8.0, 11.4), (3.2, 15.2)])
ribbon = ribbon.buffer(-0.6, 64, join_style=1).buffer(0.6, 64, join_style=1).intersection(box(0, 0, 16, 16))
outline = ribbon.difference(ribbon.buffer(-1.3, 64, join_style=2))
(out / "verso-keep-symbolic.svg").write_text(svg(ribbon, "A memory kept (Keep, its isSaved): a bookmark ribbon, filled; a star means a rating, a heart a favorite."))
(out / "verso-keep-outline-symbolic.svg").write_text(svg(outline, "A memory not kept yet, where the ribbon keeps it: the ribbon's outline."))
print("ok")
