#!/usr/bin/env python3
"""Generate PhotoSorter macOS app icon assets."""

from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT_DIR = Path(__file__).resolve().parent.parent
RESOURCES_DIR = ROOT_DIR / "apps" / "macos" / "Resources"
ICON_NAME = "PhotoSorter"
ICONSET_DIR = RESOURCES_DIR / f"{ICON_NAME}.iconset"
ICON_1024_PATH = RESOURCES_DIR / f"{ICON_NAME}-1024.png"
ICNS_PATH = RESOURCES_DIR / f"{ICON_NAME}.icns"


def diagonal_gradient(size: int, start: tuple[int, int, int], end: tuple[int, int, int]) -> Image.Image:
    base = Image.new("RGBA", (size, size), start + (255,))
    overlay = Image.new("RGBA", (size, size), end + (255,))
    mask = Image.linear_gradient("L").rotate(35, expand=True).resize((size, size), Image.Resampling.BICUBIC)
    return Image.composite(overlay, base, mask)


def draw_background(size: int) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    inset = int(size * 0.055)
    radius = int(size * 0.21)
    bounds = (inset, inset, size - inset, size - inset)
    mask_draw.rounded_rectangle(bounds, radius=radius, fill=255)

    # Soft drop shadow outside the squircle.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_inset = inset + int(size * 0.01)
    shadow_draw.rounded_rectangle(
        (shadow_inset, shadow_inset + int(size * 0.012), size - shadow_inset, size - shadow_inset + int(size * 0.012)),
        radius=radius,
        fill=(0, 0, 0, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(size * 0.03)))
    canvas.alpha_composite(shadow)

    bg = diagonal_gradient(size, (11, 43, 78), (33, 185, 152))

    # Center glow for depth.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_radius = int(size * 0.36)
    center = (int(size * 0.54), int(size * 0.46))
    for i in range(5, 0, -1):
        alpha = int(18 * i)
        expand = int(glow_radius * (i / 5))
        glow_draw.ellipse(
            (
                center[0] - expand,
                center[1] - expand,
                center[0] + expand,
                center[1] + expand,
            ),
            fill=(255, 255, 255, alpha),
        )
    bg.alpha_composite(glow)

    canvas.paste(bg, (0, 0), mask)
    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    border_draw = ImageDraw.Draw(border)
    border_draw.rounded_rectangle(
        bounds,
        radius=radius,
        outline=(255, 255, 255, 75),
        width=max(2, size // 400),
    )
    canvas.alpha_composite(border)
    return canvas


def build_card(width: int, height: int, sky: tuple[int, int, int], land: tuple[int, int, int]) -> Image.Image:
    card = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(card)
    radius = int(width * 0.085)

    draw.rounded_rectangle((0, 0, width - 1, height - 1), radius=radius, fill=(247, 250, 255, 255), outline=(255, 255, 255, 210), width=max(2, width // 90))

    margin = int(width * 0.08)
    inner = (margin, margin, width - margin, height - margin)
    inner_w = inner[2] - inner[0]
    inner_h = inner[3] - inner[1]
    scene = Image.new("RGBA", (inner_w, inner_h), sky + (255,))
    scene_draw = ImageDraw.Draw(scene)
    ground_top = int(inner_h * 0.66)
    scene_draw.rectangle((0, ground_top, inner_w, inner_h), fill=land + (255,))
    scene_draw.polygon(
        [
            (int(inner_w * 0.08), int(inner_h * 0.78)),
            (int(inner_w * 0.35), int(inner_h * 0.38)),
            (int(inner_w * 0.56), int(inner_h * 0.78)),
        ],
        fill=(80, 125, 152, 220),
    )
    scene_draw.polygon(
        [
            (int(inner_w * 0.34), int(inner_h * 0.78)),
            (int(inner_w * 0.66), int(inner_h * 0.30)),
            (int(inner_w * 0.93), int(inner_h * 0.78)),
        ],
        fill=(50, 97, 125, 240),
    )
    scene_draw.ellipse(
        (int(inner_w * 0.66), int(inner_h * 0.13), int(inner_w * 0.85), int(inner_h * 0.32)),
        fill=(255, 219, 121, 235),
    )
    card.alpha_composite(scene, (margin, margin))
    return card


def paste_with_shadow(canvas: Image.Image, image: Image.Image, center: tuple[int, int], angle: float) -> None:
    rotated = image.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    alpha = rotated.split()[-1]
    shadow = Image.new("RGBA", rotated.size, (0, 0, 0, 0))
    shadow_tint = Image.new("RGBA", rotated.size, (0, 0, 0, 130))
    shadow.paste(shadow_tint, (0, 0), alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(12))
    x = int(center[0] - rotated.width / 2)
    y = int(center[1] - rotated.height / 2)
    canvas.alpha_composite(shadow, (x + 8, y + 10))
    canvas.alpha_composite(rotated, (x, y))


def polar(center: tuple[int, int], radius: float, degrees: float) -> tuple[float, float]:
    radians = math.radians(degrees)
    return (
        center[0] + radius * math.cos(radians),
        center[1] + radius * math.sin(radians),
    )


def draw_arrowhead(draw: ImageDraw.ImageDraw, tip: tuple[float, float], degrees: float, color: tuple[int, int, int, int], length: int = 44, spread: int = 18) -> None:
    radians = math.radians(degrees)
    back_x = tip[0] - length * math.cos(radians)
    back_y = tip[1] - length * math.sin(radians)
    normal_x = spread * math.cos(radians + math.pi / 2)
    normal_y = spread * math.sin(radians + math.pi / 2)
    draw.polygon(
        [
            tip,
            (back_x + normal_x, back_y + normal_y),
            (back_x - normal_x, back_y - normal_y),
        ],
        fill=color,
    )


def draw_sort_cycle(icon: Image.Image) -> None:
    draw = ImageDraw.Draw(icon)
    circle = (196, 196, 828, 828)
    arc_color = (240, 252, 255, 205)
    arc_width = 24
    draw.arc(circle, start=214, end=328, fill=arc_color, width=arc_width)
    draw.arc(circle, start=34, end=148, fill=arc_color, width=arc_width)

    center = (512, 512)
    radius = (circle[2] - circle[0]) / 2
    head_a = polar(center, radius, 328)
    head_b = polar(center, radius, 148)
    draw_arrowhead(draw, head_a, 328 + 90, arc_color)
    draw_arrowhead(draw, head_b, 148 + 90, arc_color)

    # Accent sparkles.
    sparkle = (255, 246, 219, 235)
    for cx, cy, r in ((744, 250, 10), (266, 736, 8), (772, 724, 7)):
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=sparkle)


def build_icon_1024() -> Image.Image:
    icon = draw_background(1024)
    back_left = build_card(350, 252, (115, 193, 224), (66, 162, 112))
    back_right = build_card(350, 252, (98, 176, 214), (55, 151, 102))
    front = build_card(390, 282, (126, 206, 230), (71, 168, 115))

    paste_with_shadow(icon, back_left, (370, 514), angle=-12)
    paste_with_shadow(icon, back_right, (640, 440), angle=11)
    paste_with_shadow(icon, front, (510, 560), angle=-1.5)
    draw_sort_cycle(icon)
    return icon


def write_iconset(icon_1024: Image.Image) -> None:
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    if ICONSET_DIR.exists():
        shutil.rmtree(ICONSET_DIR)
    ICONSET_DIR.mkdir(parents=True)

    specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for filename, size in specs:
        out = icon_1024.resize((size, size), Image.Resampling.LANCZOS)
        out.save(ICONSET_DIR / filename, format="PNG")


def write_icns() -> None:
    if shutil.which("iconutil") is None:
        raise RuntimeError("iconutil not found (macOS required to generate .icns)")
    subprocess.run(
        [
            "iconutil",
            "-c",
            "icns",
            str(ICONSET_DIR),
            "-o",
            str(ICNS_PATH),
        ],
        check=True,
    )


def main() -> None:
    icon_1024 = build_icon_1024()
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    icon_1024.save(ICON_1024_PATH, format="PNG")
    write_iconset(icon_1024)
    write_icns()
    print(f"Generated {ICON_1024_PATH}")
    print(f"Generated {ICNS_PATH}")


if __name__ == "__main__":
    main()
