# Verso's symbolic icon, on a 16-pixel grid: the app icon's print as one solid shape, with the lens cut out of it above
# the word on its strip, and its corner turned. One solid colour, as GTK recolours it; holes by the even-odd rule.
# Writes dev.hviid.Verso-symbolic.svg into the folder given:
# python3 linux/packaging/icons/sources/symbolic.py linux/packaging/icons
import math, sys, pathlib
out = pathlib.Path(sys.argv[1])

def f(v): return f"{v:.3f}".rstrip("0").rstrip(".")

def folded(l, t, r, b, rad, fold):
    """A rounded rectangle whose bottom right corner is cut off along the fold."""
    return (f"M{f(l+rad)} {f(t)} H{f(r-rad)} A{f(rad)} {f(rad)} 0 0 1 {f(r)} {f(t+rad)} V{f(b-fold)} "
            f"L{f(r-fold)} {f(b)} H{f(l+rad)} A{f(rad)} {f(rad)} 0 0 1 {f(l)} {f(b-rad)} "
            f"V{f(t+rad)} A{f(rad)} {f(rad)} 0 0 1 {f(l+rad)} {f(t)} Z")

def flap(r, b, fold, gap):
    """The turned corner: the gap around it (a hole) and the flap itself."""
    a = (r - fold - gap, b - fold - gap)
    hole = f"M{f(a[0])} {f(a[1])} H{f(r)} V{f(b-fold)} L{f(r-fold)} {f(b)} H{f(a[0])} Z"
    tri = f"M{f(r)} {f(b-fold)} L{f(r-fold)} {f(b)} L{f(r-fold)} {f(b-fold)} Z"
    return hole + " " + tri

def ring(cx, cy, outer, inner, gap, dot):
    """The lens: five segments with gaps where the app icon's are (one at the top), and its centre."""
    parts = []
    mid = (outer + inner) / 2
    half = math.degrees(gap / 2 / mid)
    for k in range(5):
        a0 = -90 + 72 * k + half
        a1 = -90 + 72 * (k + 1) - half
        p = lambda r, a: (cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))
        (x0, y0), (x1, y1) = p(outer, a0), p(outer, a1)
        (x2, y2), (x3, y3) = p(inner, a1), p(inner, a0)
        parts.append(f"M{f(x0)} {f(y0)} A{f(outer)} {f(outer)} 0 0 1 {f(x1)} {f(y1)} L{f(x2)} {f(y2)} "
                     f"A{f(inner)} {f(inner)} 0 0 0 {f(x3)} {f(y3)} Z")
    if dot:
        parts.append(f"M{f(cx+dot)} {f(cy)} A{f(dot)} {f(dot)} 0 1 0 {f(cx-dot)} {f(cy)} A{f(dot)} {f(dot)} 0 1 0 {f(cx+dot)} {f(cy)} Z")
    return " ".join(parts)

def scribble(x, y, w, h=0.85, waves=1.5, amp=0.55):
    """A short hand-written line as a hole: an even wave, h thick, rising a little at its end."""
    n = 40
    centre = []
    for i in range(n + 1):
        t = i / n
        centre.append((x + w * t, y + amp * math.sin(2 * math.pi * waves * t) - 0.5 * t * t))
    top, bottom = [], []
    for i, (cx, cy) in enumerate(centre):
        (ax, ay), (bx, by) = centre[max(i - 1, 0)], centre[min(i + 1, n)]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        nx, ny = -dy / length * h / 2, dx / length * h / 2
        top.append((cx + nx, cy + ny)); bottom.append((cx - nx, cy - ny))
    points = top + bottom[::-1]
    return "M" + " L".join(f"{f(px)} {f(py)}" for px, py in points) + " Z"

def svg(d, note):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n  <!-- {note} -->\n'
            f'  <path fill="#000000" fill-rule="evenodd" d="{d}"/>\n</svg>\n')

d = " ".join([folded(0.5, 0.5, 15.5, 15.5, 3, 4.2), ring(8, 6.6, 4.4, 2.8, 0.8, 1.15), scribble(2.6, 13.1, 6.4),
              flap(15.5, 15.5, 4.2, 0.8)])
note = ("Verso's symbolic icon (the top bar, notifications, Verso Drive in Files' sidebar and in Preferences): the app\n"
        "       icon's print as one solid shape, the lens's ring in five segments and its centre, the word on its strip and the\n"
        "       turned corner cut out. Drawn by sources/symbolic.py.")
(out / "dev.hviid.Verso-symbolic.svg").write_text(svg(d, note))
