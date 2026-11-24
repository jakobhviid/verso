# Verso's Live Photo icon, on a 16-pixel grid: a dot, a ring, and round them a ring in Verso's five segments, the
# lens's rhythm, as Live Photos are marked on the Mac. One solid colour (GTK recolours it), holes by the even-odd rule.
# It marks a Live Photo's badge in the grid and Live in the viewer. Writes verso-live-symbolic.svg into the folder
# given: python3 linux/packaging/icons/sources/live.py linux/packaging/icons
import math, sys, pathlib
out = pathlib.Path(sys.argv[1])

def f(v): return f"{v:.3f}".rstrip("0").rstrip(".")

def circle(cx, cy, r):
    return f"M{f(cx+r)} {f(cy)} A{f(r)} {f(r)} 0 1 0 {f(cx-r)} {f(cy)} A{f(r)} {f(r)} 0 1 0 {f(cx+r)} {f(cy)} Z"

def annulus(cx, cy, outer, inner):
    return circle(cx, cy, outer) + " " + circle(cx, cy, inner)

def segments(cx, cy, outer, inner, n, gap, start=-90.0, sweep=360.0):
    """n pieces of a ring between start and start + sweep degrees, gap pixels apart."""
    mid = (outer + inner) / 2
    half = math.degrees(gap / 2 / mid)
    step = sweep / n
    p = lambda r, a: (cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))
    parts = []
    for k in range(n):
        a0, a1 = start + step * k + half, start + step * (k + 1) - half
        (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p(outer, a0), p(outer, a1), p(inner, a1), p(inner, a0)
        large = 1 if a1 - a0 > 180 else 0
        parts.append(f"M{f(x0)} {f(y0)} A{f(outer)} {f(outer)} 0 {large} 1 {f(x1)} {f(y1)} L{f(x2)} {f(y2)} "
                     f"A{f(inner)} {f(inner)} 0 {large} 0 {f(x3)} {f(y3)} Z")
    return " ".join(parts)

def svg(d, note):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n  <!-- {note} -->\n'
            f'  <path fill="#000000" fill-rule="evenodd" d="{d}"/>\n</svg>\n')

d = " ".join([circle(8, 8, 1.75), annulus(8, 8, 4.6, 3.5), segments(8, 8, 7.6, 5.9, 5, 1.1)])
note = ("A Live Photo (its badge in the grid, the viewer's Live button): a dot, a ring, and round them a ring in Verso's\n"
        "       five segments. Drawn by sources/live.py.")
(out / "verso-live-symbolic.svg").write_text(svg(d, note))
