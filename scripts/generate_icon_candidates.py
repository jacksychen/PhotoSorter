#!/usr/bin/env python3
"""Generate multiple PhotoSorter icon candidates for visual selection."""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT_DIR / "apps" / "macos" / "Resources" / "icon-candidates"
SIZE = 1024


def diagonal_gradient(size: int, start: tuple[int, int, int], end: tuple[int, int, int], angle: float) -> Image.Image:
    base = Image.new("RGBA", (size, size), start + (255,))
    overlay = Image.new("RGBA", (size, size), end + (255,))
    mask = Image.linear_gradient("L").rotate(angle, expand=True).resize((size, size), Image.Resampling.BICUBIC)
    return Image.composite(overlay, base, mask)


def base_icon(start: tuple[int, int, int], end: tuple[int, int, int], angle: float = 38) -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bg = diagonal_gradient(SIZE, start, end, angle)

    mask = Image.new("L", (SIZE, SIZE), 0)
    inset = int(SIZE * 0.055)
    radius = int(SIZE * 0.215)
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, SIZE - inset, SIZE - inset), radius=radius, fill=255)
    canvas.paste(bg, (0, 0), mask)

    border = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (inset, inset, SIZE - inset, SIZE - inset),
        radius=radius,
        outline=(255, 255, 255, 80),
        width=3,
    )
    canvas.alpha_composite(border)
    return canvas


def simple_photo_card(w: int, h: int, sky: tuple[int, int, int], land: tuple[int, int, int]) -> Image.Image:
    card = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(card)
    radius = int(w * 0.08)
    frame = (243, 246, 250, 255)
    draw.rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=frame, outline=(255, 255, 255, 210), width=3)

    margin = int(w * 0.085)
    iw = w - margin * 2
    ih = h - margin * 2
    scene = Image.new("RGBA", (iw, ih), sky + (255,))
    sd = ImageDraw.Draw(scene)
    sd.rectangle((0, int(ih * 0.68), iw, ih), fill=land + (255,))
    sd.polygon([(int(iw * 0.12), int(ih * 0.78)), (int(iw * 0.44), int(ih * 0.33)), (int(iw * 0.64), int(ih * 0.78))], fill=(85, 127, 160, 230))
    sd.polygon([(int(iw * 0.36), int(ih * 0.78)), (int(iw * 0.72), int(ih * 0.26)), (int(iw * 0.95), int(ih * 0.78))], fill=(56, 97, 132, 240))
    sd.ellipse((int(iw * 0.68), int(ih * 0.11), int(iw * 0.86), int(ih * 0.30)), fill=(254, 220, 122, 240))
    card.alpha_composite(scene, (margin, margin))
    return card


def paste_shadowed(base: Image.Image, layer: Image.Image, center: tuple[int, int], angle: float, blur: int = 10) -> None:
    rotated = layer.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    alpha = rotated.split()[-1]
    shadow = Image.new("RGBA", rotated.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", rotated.size, (0, 0, 0, 140)), (0, 0), alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    x = int(center[0] - rotated.width / 2)
    y = int(center[1] - rotated.height / 2)
    base.alpha_composite(shadow, (x + 7, y + 11))
    base.alpha_composite(rotated, (x, y))


def candidate_a() -> Image.Image:
    icon = base_icon((15, 46, 83), (36, 160, 135), 35)
    left = simple_photo_card(350, 252, (115, 194, 223), (66, 160, 112))
    right = simple_photo_card(350, 252, (95, 175, 212), (58, 150, 101))
    front = simple_photo_card(390, 282, (123, 204, 230), (70, 169, 114))
    paste_shadowed(icon, left, (360, 510), -11)
    paste_shadowed(icon, right, (655, 435), 12)
    paste_shadowed(icon, front, (520, 562), -2)
    d = ImageDraw.Draw(icon)
    d.arc((210, 208, 822, 820), start=212, end=340, fill=(240, 252, 255, 220), width=25)
    d.arc((202, 210, 814, 822), start=24, end=152, fill=(240, 252, 255, 220), width=25)
    d.polygon([(774, 393), (732, 355), (754, 428)], fill=(240, 252, 255, 220))
    d.polygon([(253, 626), (294, 662), (270, 592)], fill=(240, 252, 255, 220))
    return icon


def candidate_b() -> Image.Image:
    icon = base_icon((30, 39, 72), (6, 121, 146), 50)
    d = ImageDraw.Draw(icon)
    lens = (224, 224, 800, 800)
    d.ellipse(lens, fill=(24, 53, 90, 225), outline=(165, 207, 240, 160), width=5)
    for r, a in ((240, 140), (198, 120), (152, 160), (108, 190)):
        d.ellipse((512 - r, 512 - r, 512 + r, 512 + r), fill=(80, 180, 212, a))
    d.ellipse((430, 430, 594, 594), fill=(25, 44, 72, 230), outline=(184, 228, 250, 180), width=4)
    d.ellipse((392, 392, 450, 450), fill=(255, 255, 255, 105))

    card1 = simple_photo_card(265, 190, (127, 201, 223), (58, 158, 116))
    card2 = simple_photo_card(265, 190, (111, 187, 221), (55, 147, 105))
    paste_shadowed(icon, card1, (355, 735), -10, blur=8)
    paste_shadowed(icon, card2, (665, 735), 9, blur=8)

    d.arc((138, 138, 886, 886), start=196, end=302, fill=(238, 247, 255, 220), width=23)
    d.arc((138, 138, 886, 886), start=20, end=126, fill=(238, 247, 255, 220), width=23)
    d.polygon([(707, 230), (662, 194), (684, 270)], fill=(238, 247, 255, 220))
    d.polygon([(321, 790), (366, 825), (343, 753)], fill=(238, 247, 255, 220))
    return icon


def candidate_c() -> Image.Image:
    icon = base_icon((74, 43, 108), (18, 148, 128), 22)
    d = ImageDraw.Draw(icon)
    tile_w = 272
    tile_h = 202
    centers = [(350, 360), (670, 360), (350, 660), (670, 660)]
    tints = [
        ((145, 206, 234), (77, 168, 121)),
        ((127, 191, 229), (67, 156, 114)),
        ((160, 211, 238), (78, 173, 126)),
        ((120, 188, 222), (66, 152, 108)),
    ]
    for i, center in enumerate(centers):
        card = simple_photo_card(tile_w, tile_h, tints[i][0], tints[i][1])
        angle = -6 if i % 2 == 0 else 5
        paste_shadowed(icon, card, center, angle, blur=7)

    # Selection accent and reorder arrow.
    d.rounded_rectangle((532, 548, 824, 771), radius=28, outline=(251, 220, 126, 245), width=10)
    d.line((248, 160, 768, 160), fill=(242, 246, 254, 210), width=24)
    d.polygon([(765, 160), (705, 125), (705, 195)], fill=(242, 246, 254, 210))
    return icon


def candidate_d() -> Image.Image:
    icon = base_icon((26, 59, 105), (72, 175, 132), 42)
    d = ImageDraw.Draw(icon)
    # Folder.
    d.rounded_rectangle((178, 334, 846, 780), radius=70, fill=(231, 196, 118, 245), outline=(255, 232, 170, 180), width=4)
    d.rounded_rectangle((198, 280, 522, 410), radius=46, fill=(240, 210, 141, 248))
    inner = (238, 404, 786, 730)
    d.rounded_rectangle(inner, radius=40, fill=(248, 224, 165, 210))

    photo = simple_photo_card(420, 300, (122, 200, 230), (67, 162, 113))
    paste_shadowed(icon, photo, (512, 564), -2, blur=7)

    # Sort glyph.
    d.arc((236, 160, 788, 712), start=210, end=320, fill=(240, 250, 255, 220), width=23)
    d.arc((236, 160, 788, 712), start=30, end=140, fill=(240, 250, 255, 220), width=23)
    d.polygon([(709, 287), (665, 252), (688, 326)], fill=(240, 250, 255, 220))
    d.polygon([(318, 587), (363, 621), (340, 550)], fill=(240, 250, 255, 220))
    return icon


def candidate_e() -> Image.Image:
    icon = base_icon((19, 30, 70), (8, 154, 166), 52)
    d = ImageDraw.Draw(icon)
    center = (512, 512)
    petals = [
        ((255, 116, 96, 225), 0),
        ((255, 196, 94, 225), 60),
        ((78, 201, 140, 225), 120),
        ((88, 188, 252, 225), 180),
        ((130, 154, 255, 225), 240),
        ((212, 126, 255, 225), 300),
    ]
    for color, deg in petals:
        rad = math.radians(deg)
        x = center[0] + int(math.cos(rad) * 118)
        y = center[1] + int(math.sin(rad) * 118)
        d.ellipse((x - 180, y - 112, x + 180, y + 112), fill=color)
    icon = icon.filter(ImageFilter.GaussianBlur(0.25))
    d = ImageDraw.Draw(icon)
    d.ellipse((322, 322, 702, 702), fill=(14, 28, 54, 195), outline=(235, 245, 255, 170), width=4)
    card = simple_photo_card(360, 260, (127, 206, 234), (71, 167, 117))
    paste_shadowed(icon, card, (512, 530), -1, blur=9)
    d.arc((190, 190, 834, 834), start=205, end=336, fill=(244, 251, 255, 220), width=22)
    d.arc((190, 190, 834, 834), start=26, end=157, fill=(244, 251, 255, 220), width=22)
    d.polygon([(766, 372), (724, 338), (746, 409)], fill=(244, 251, 255, 220))
    d.polygon([(259, 642), (302, 677), (279, 605)], fill=(244, 251, 255, 220))
    return icon


def candidate_f() -> Image.Image:
    icon = base_icon((17, 49, 80), (39, 158, 192), 28)
    d = ImageDraw.Draw(icon)
    photo = simple_photo_card(610, 438, (126, 205, 233), (71, 168, 117))
    paste_shadowed(icon, photo, (512, 522), -1.2, blur=8)

    # "PS" monogram.
    font = ImageFont.load_default(size=190)
    d.text((332, 318), "PS", font=font, fill=(242, 248, 255, 230))
    d.rounded_rectangle((306, 300, 720, 540), radius=42, outline=(242, 248, 255, 120), width=3)

    d.arc((146, 146, 878, 878), start=200, end=304, fill=(246, 252, 255, 220), width=21)
    d.arc((146, 146, 878, 878), start=16, end=120, fill=(246, 252, 255, 220), width=21)
    d.polygon([(709, 220), (669, 188), (688, 256)], fill=(246, 252, 255, 220))
    d.polygon([(319, 804), (361, 836), (339, 767)], fill=(246, 252, 255, 220))
    return icon


def preview_grid(images: list[tuple[str, Image.Image]]) -> Image.Image:
    cols = 3
    rows = 2
    thumb = 300
    pad = 36
    title_h = 54
    canvas = Image.new("RGBA", (cols * (thumb + pad) + pad, rows * (thumb + pad + title_h) + pad), (13, 17, 24, 255))
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=24)
    for i, (name, image) in enumerate(images):
        r = i // cols
        c = i % cols
        x = pad + c * (thumb + pad)
        y = pad + r * (thumb + pad + title_h)
        thumb_img = image.resize((thumb, thumb), Image.Resampling.LANCZOS)
        canvas.alpha_composite(thumb_img, (x, y))
        draw.text((x + 8, y + thumb + 14), name, fill=(232, 238, 248, 255), font=font)
    return canvas


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    candidates: list[tuple[str, Image.Image]] = [
        ("A_Stack", candidate_a()),
        ("B_Lens", candidate_b()),
        ("C_Grid", candidate_c()),
        ("D_Folder", candidate_d()),
        ("E_Orbit", candidate_e()),
        ("F_Monogram", candidate_f()),
    ]

    for name, image in candidates:
        path = OUT_DIR / f"{name}.png"
        image.save(path, format="PNG")
        print(f"Generated {path}")

    grid = preview_grid(candidates)
    grid_path = OUT_DIR / "preview-grid.png"
    grid.save(grid_path, format="PNG")
    print(f"Generated {grid_path}")


if __name__ == "__main__":
    main()
