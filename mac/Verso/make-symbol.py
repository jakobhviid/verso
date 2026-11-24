#!/usr/bin/env python3
"""Finder's sidebar symbol for Verso Drive: the lens of Verso's app icon (make-icons.py), as the menu bar and Messages
show Verso: its ring in five segments with a gap at the top, as the icon's ring carries five colours, and its glass
inside, a rim with the light on it. The same in the Dev build: its app icon tells the two apart.

Writes an SF Symbols template (v6.0, "variable"): three source glyphs, Ultralight, Regular and Black at the small
scale, from which macOS interpolates every weight and scale. They are made from one geometry with three stroke
widths, so their paths match command for command, as interpolation needs; only lines and cubic curves are used.
Glyph coordinates are Apple's: x from the left margin, y up from the baseline (negative), cap height 70.459. Each
segment is a layer of its own, which asks for the icon's colour of it where a renderer draws in colour (multicolor);
in one colour, as Finder's sidebar draws its symbols, it is the same shape. make-icons.py runs it, and draws its
glyphs into its preview; on its own:

    mac/Verso/make-symbol.py <output.svg>
"""

import math
import sys

CAP = 70.459
SIDE_BEARING = 4.0
# Template columns (the centres Apple's template gives each weight) and stroke widths.
WEIGHTS = {"Ultralight-S": (559.711, 2.2), "Regular-S": (1449.84, 6.6), "Black-S": (2933.4, 11.6)}
# Each layer's colour where it is drawn in colour: the ring's five, nearest the icon's (red, pink, amber, blue,
# green, from the top round to the right), and the glass in the accent colour.
LAYER_COLOURS = ("systemRedColor", "systemPinkColor", "systemYellowColor", "systemBlueColor", "systemGreenColor",
                 "tintColor")


def fmt(value):
    return f"{value:.3f}".rstrip("0").rstrip(".")


def point_text(point):
    return f"{fmt(point[0])} {fmt(point[1])}"


def arc(centre_x, centre_y, radius, start, end, move=False):
    """A circular arc as cubic curves, in pieces of at most 90 degrees (angles in degrees, counted anticlockwise as
    seen, from the right)."""
    pieces = max(1, math.ceil(abs(end - start) / 90))
    step = (end - start) / pieces
    handle = 4 / 3 * math.tan(math.radians(step) / 4)

    def point(angle):
        return centre_x + radius * math.cos(math.radians(angle)), centre_y - radius * math.sin(math.radians(angle))

    commands = [f"M{point_text(point(start))}"] if move else []
    for index in range(pieces):
        angle_from, angle_to = start + index * step, start + (index + 1) * step
        from_point, to_point = point(angle_from), point(angle_to)
        from_tangent = (-math.sin(math.radians(angle_from)), -math.cos(math.radians(angle_from)))
        to_tangent = (-math.sin(math.radians(angle_to)), -math.cos(math.radians(angle_to)))
        commands.append(
            f"C{fmt(from_point[0] + handle * radius * from_tangent[0])} "
            f"{fmt(from_point[1] + handle * radius * from_tangent[1])} "
            f"{fmt(to_point[0] - handle * radius * to_tangent[0])} {fmt(to_point[1] - handle * radius * to_tangent[1])} "
            f"{point_text(to_point)}")
    return commands


def ellipse(centre_x, centre_y, radius_x, radius_y, rotation):
    """A closed ellipse as four cubic curves, a quarter each, anticlockwise as seen, turned by `rotation` degrees."""
    handle = 4 / 3 * math.tan(math.pi / 8)
    turn = math.radians(rotation)

    def place(x, y):
        """A point in the ellipse's own axes (y up), on the glyph's grid (y down)."""
        return (centre_x + x * math.cos(turn) - y * math.sin(turn), centre_y - x * math.sin(turn) - y * math.cos(turn))

    def at(angle):
        return radius_x * math.cos(angle), radius_y * math.sin(angle)

    def tangent(angle):
        return -radius_x * math.sin(angle), radius_y * math.cos(angle)

    commands = [f"M{point_text(place(*at(0)))}"]
    for index in range(4):
        angle_from, angle_to = index * math.pi / 2, (index + 1) * math.pi / 2
        (from_x, from_y), (to_x, to_y) = at(angle_from), at(angle_to)
        (from_dx, from_dy), (to_dx, to_dy) = tangent(angle_from), tangent(angle_to)
        controls = ((from_x + handle * from_dx, from_y + handle * from_dy), (to_x - handle * to_dx, to_y - handle * to_dy),
                    (to_x, to_y))
        commands.append("C" + " ".join(point_text(place(*point)) for point in controls))
    commands.append("Z")
    return " ".join(commands)


def glyph(width):
    """The glyph at one stroke width, as its layers' paths (the five segments, then the glass), and its advance.
    Proportions follow the width, so the heavy weights keep a glass inside the ring; the commands stay the same at
    every width."""
    radius = (80.0 + width * 0.3) / 2  # a little taller than the capitals, as a round glyph is
    centre_x, centre_y = SIDE_BEARING + radius, -CAP / 2
    ring_inner = radius - (5.0 + width * 1.1)
    gap = 8.0 + width * 0.5
    layers = []
    # The ring in five segments, a gap at the top and every fifth of the way round, as the icon's ring.
    for index in range(5):
        angle_from = 90 - index * 72 - gap / 2
        angle_to = angle_from - 72 + gap
        segment = arc(centre_x, centre_y, radius, angle_from, angle_to, move=True)
        x = centre_x + ring_inner * math.cos(math.radians(angle_to))
        y = centre_y - ring_inner * math.sin(math.radians(angle_to))
        segment.append(f"L{fmt(x)} {fmt(y)}")
        segment += arc(centre_x, centre_y, ring_inner, angle_to, angle_from)
        segment.append("Z")
        layers.append(" ".join(segment))
    # The glass: its rim, clear of the ring (the inner circle runs the other way, so it is the rim's hole), and the
    # light on it at the upper left, as the icon's.
    glass = ring_inner - (3.0 + width * 0.45)
    rim = glass - width
    outline = arc(centre_x, centre_y, glass, 90, -270, move=True) + ["Z"]
    outline += arc(centre_x, centre_y, rim, -270, 90, move=True) + ["Z"]
    light = ellipse(centre_x - rim * 0.34, centre_y - rim * 0.38, rim * 0.3 + width * 0.12,
                    rim * 0.18 + width * 0.08, 35)
    layers.append(" ".join(outline) + " " + light)
    return layers, 2 * radius + 2 * SIDE_BEARING


def template():
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!-- Verso Drive's Finder sidebar symbol, the lens of Verso's app icon, written by mac/Verso/make-symbol.py. -->",
        '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3300 2200">',
        ' <g id="Notes">',
        '  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.6.0</text>',
        '  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">Verso Drive</text>',
        ' </g>',
        ' <g id="Guides">',
    ]
    for scale, baseline in (("S", 696), ("M", 1126), ("L", 1556)):
        guide = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
        lines.append(f'  <line id="Baseline-{scale}" {guide} x1="263" x2="3036" y1="{baseline}" y2="{baseline}"/>')
        lines.append(f'  <line id="Capline-{scale}" {guide} x1="263" x2="3036" y1="{fmt(baseline - CAP)}" '
                     f'y2="{fmt(baseline - CAP)}"/>')
    glyphs = []
    for name, (centre, width) in WEIGHTS.items():
        layers, advance = glyph(width)
        margin_left = centre - advance / 2
        margin = 'style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"'
        lines.append(f'  <line id="left-margin-{name}" {margin} x1="{fmt(margin_left)}" x2="{fmt(margin_left)}" '
                     f'y1="600.785" y2="720.121"/>')
        lines.append(f'  <line id="right-margin-{name}" {margin} x1="{fmt(margin_left + advance)}" '
                     f'x2="{fmt(margin_left + advance)}" y1="600.785" y2="720.121"/>')
        glyphs.append(f'  <g id="{name}" transform="matrix(1 0 0 1 {fmt(margin_left)} 696)">')
        for index, (path, colour) in enumerate(zip(layers, LAYER_COLOURS)):
            glyphs.append(f'   <path class="monochrome-{index} multicolor-{index}:{colour} hierarchical-{index}:primary" '
                          f'd="{path}"/>')
        glyphs.append("  </g>")
    lines.append(" </g>")
    lines.append(' <g id="Symbols">')
    lines += glyphs
    lines.append(" </g>")
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    open(sys.argv[1], "w").write(template())
