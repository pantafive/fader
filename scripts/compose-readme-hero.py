#!/usr/bin/env python3
"""Compose the README hero: three popover captures side by side on a
transparent canvas, center one the focal point, sides lifted slightly.

Inputs are raw window captures (shadow on transparent background, the
same kind compose-screenshots.sh consumes). Placement is computed from
each capture's opaque core (alpha ~255) so shadows overlap the gaps
instead of inflating them.

Usage: compose-readme-hero.py left.png center.png right.png out.png
"""

import sys

from PIL import Image

GAP = 24  # px between opaque cores
CENTER_DROP = 60  # center core's top sits this far below the sides' shared top line
MARGIN = 4  # canvas padding beyond the shadows


def core_box(img):
    """Bounding box of the near-opaque pixels — the window without its shadow."""
    alpha = img.getchannel("A").point(lambda a: 255 if a >= 250 else 0)
    box = alpha.getbbox()
    if box is None:
        raise SystemExit("capture has no opaque pixels")
    return box


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    images = [Image.open(p).convert("RGBA") for p in sys.argv[1:4]]
    cores = [core_box(i) for i in images]

    # Horizontal: cores in a row, GAP apart.
    core_x = []
    x = 0
    for left, _, right, _ in cores:
        core_x.append(x)
        x += (right - left) + GAP

    # Vertical: side cores share one top line, the center drops below it —
    # the rhythm stays fixed no matter how the capture heights differ;
    # only the bottom edge is ragged, and deliberately so.
    core_top = [0, CENTER_DROP, 0]
    origins = []
    for img, (left, top, _, _), cx, cy in zip(images, cores, core_x, core_top):
        origins.append((cx - left, cy - top))

    # Shift so the full captures (shadows included) start at MARGIN.
    min_x = min(o[0] for o in origins)
    min_y = min(o[1] for o in origins)
    origins = [(ox - min_x + MARGIN, oy - min_y + MARGIN) for ox, oy in origins]
    width = max(ox + img.width for (ox, _), img in zip(origins, images)) + MARGIN
    height = max(oy + img.height for (_, oy), img in zip(origins, images)) + MARGIN

    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    for img, origin in zip(images, origins):
        canvas.alpha_composite(img, origin)
    canvas.save(sys.argv[4])
    print(f"{sys.argv[4]} ({width}x{height})")


if __name__ == "__main__":
    main()
