"""Draws the app icon: a basketball, its dotted arc and the hoop it drops into, on navy.

    python scripts/make_icon.py            # writes Assets/AppIcon.png (1024 x 1024, opaque)

Needs Pillow. Drawn at 4x and scaled down for smooth edges. iOS rounds the corners itself and does not
allow transparency in app icons, so the image is a full opaque square. xtool.yml's iconPath points here and the
start screen shows the same file.
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
K = 4  # supersampling factor
S = SIZE * K

NAVY_TOP, NAVY_BOTTOM = (13, 24, 43), (28, 50, 82)
ORANGE, ORANGE_DARK, SEAM = (242, 140, 40), (205, 98, 22), (58, 30, 12)
RIM = (236, 84, 42)
WHITE = (255, 255, 255)


def p(x: float, y: float):
    return (x * S, y * S)


def gradient(img: Image.Image) -> None:
    d = ImageDraw.Draw(img)
    for y in range(S):
        f = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * f) for a, b in zip(NAVY_TOP, NAVY_BOTTOM)))


def bezier(p0, p1, p2, t):
    return tuple((1 - t) ** 2 * a + 2 * (1 - t) * t * b + t * t * c for a, b, c in zip(p0, p1, p2))


def draw_icon() -> Image.Image:
    img = Image.new("RGB", (S, S))
    gradient(img)
    over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)

    # Backboard (behind the rim): a soft panel with the shooter's square. dy moves the whole hoop down.
    dy = 0.10
    d.rounded_rectangle([p(0.50, 0.12 + dy), p(0.86, 0.38 + dy)], radius=0.03 * S, fill=(255, 255, 255, 30),
                        outline=(255, 255, 255, 220), width=round(0.014 * S))
    d.rectangle([p(0.615, 0.235 + dy), p(0.745, 0.325 + dy)], outline=(255, 255, 255, 200), width=round(0.010 * S))

    # Net: diamonds between the rim and a narrower bottom ring.
    cx, top, bottom = 0.68, 0.355 + dy, 0.52 + dy
    w_top, w_bottom, n = 0.30, 0.17, 6
    xs_top = [cx - w_top / 2 + w_top * i / n for i in range(n + 1)]
    xs_bot = [cx - w_bottom / 2 + w_bottom * i / n for i in range(n + 1)]
    net = (255, 255, 255, 215)
    lw = round(0.008 * S)
    for i in range(n + 1):
        if i < n:
            d.line([p(xs_top[i], top), p(xs_bot[i + 1], bottom)], fill=net, width=lw)
        if i > 0:
            d.line([p(xs_top[i], top), p(xs_bot[i - 1], bottom)], fill=net, width=lw)
    d.line([p(xs_bot[0], bottom), p(xs_bot[-1], bottom)], fill=net, width=lw)

    # Rim: a flat ellipse in front of the net.
    d.ellipse([p(cx - w_top / 2 - 0.01, top - 0.03), p(cx + w_top / 2 + 0.01, top + 0.03)],
              outline=RIM + (255,), width=round(0.024 * S))

    # The shot: dots from the ball's edge, peaking above the backboard and dropping into the rim's centre
    # (bigger and brighter as they get closer).
    start, ctrl, end = (0.45, 0.53), (0.55, -0.12), (0.68, top - 0.035)
    dots = 10
    for i in range(1, dots + 1):
        t = i / dots
        x, y = bezier(start, ctrl, end, t)
        r = (0.009 + 0.008 * t) * S
        d.ellipse([x * S - r, y * S - r, x * S + r, y * S + r], fill=(255, 255, 255, round(140 + 110 * t)))
    img.paste(over, (0, 0), over)

    # Ball, lower left: a darker edge for depth, then the seams, clipped to the ball.
    bx, by, br = 0.32, 0.70, 0.19
    ball = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    b = ImageDraw.Draw(ball)
    b.ellipse([p(bx - br, by - br), p(bx + br, by + br)], fill=ORANGE_DARK + (255,))
    b.ellipse([p(bx - br * 0.93, by - br * 0.95), p(bx + br * 0.90, by + br * 0.88)], fill=ORANGE + (255,))
    seam = SEAM + (255,)
    sw = round(0.014 * S)
    b.line([p(bx - br, by), p(bx + br, by)], fill=seam, width=sw)  # horizontal
    b.line([p(bx, by - br), p(bx, by + br)], fill=seam, width=sw)  # vertical
    for side in (-1, 1):  # side seams: arcs of bigger circles centred outside the ball, so they curve inward
        cxs, rs = bx + side * 1.22 * br, 0.92 * br
        b.ellipse([p(cxs - rs, by - rs), p(cxs + rs, by + rs)], outline=seam, width=sw)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).ellipse([p(bx - br, by - br), p(bx + br, by + br)], fill=255)
    img.paste(ball, (0, 0), Image.composite(ball, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=ROOT / "Assets" / "AppIcon.png")
    a = ap.parse_args()
    a.out.parent.mkdir(parents=True, exist_ok=True)
    draw_icon().save(a.out)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
