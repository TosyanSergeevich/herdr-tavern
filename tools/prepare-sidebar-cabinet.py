#!/usr/bin/env python3
"""Цельные резные сопряжения и связный подвес Tavern; зависимость: Pillow.

python3 tools/prepare-sidebar-cabinet.py
Мастера: resources/Textures/Sources/SidebarCabinet/; сведения о правах — NOTICE.
Координаты сверху слева; правая и нижняя границы crop не включаются.
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "resources/Textures"
SOURCES = OUTPUT / "Sources/SidebarCabinet"
SCALE = 4


LEAVES_OUTLINE = [
    (11, 3), (15, 4), (20, 8), (24, 16), (26, 14), (28, 14),
    (31, 19), (33, 26), (32, 36), (36, 33), (39, 29), (42, 29),
    (44, 33), (44, 39), (42, 44), (45, 42), (46, 45), (44, 51),
    (40, 57), (34, 64), (28, 67), (26, 75), (24, 82), (31, 72),
    (33, 66), (37, 63), (40, 64), (42, 67), (45, 57), (50, 50),
    (57, 44), (64, 39), (68, 38), (70, 40), (68, 46), (75, 42),
    (82, 36), (88, 34), (90, 34), (88, 39), (96, 34), (105, 33),
    (108, 34), (107, 38), (102, 45), (99, 49), (101, 50), (100, 53),
    (92, 58), (96, 60), (103, 62), (105, 64), (101, 69), (96, 73),
    (88, 77), (87, 80), (93, 76), (104, 72), (109, 72), (109, 77),
    (119, 73), (126, 73), (128, 75), (128, 78), (125, 83),
    (135, 81), (141, 83), (144, 86), (142, 89), (137, 92),
    (143, 97), (147, 103), (148, 107), (145, 109), (136, 109),
    (128, 105), (122, 108), (118, 110), (112, 109), (105, 106),
    (105, 110), (101, 112), (91, 111), (81, 109), (75, 113),
    (67, 114), (58, 112), (49, 115), (38, 114), (29, 118),
    (16, 118), (0, 118), (0, 105), (5, 99), (12, 97), (16, 83),
    (20, 70), (21, 61), (17, 59), (12, 56), (10, 52), (12, 50),
    (8, 47), (5, 43), (5, 40), (7, 38), (13, 41), (10, 36),
    (7, 31), (6, 27), (8, 23), (6, 18), (8, 14), (7, 10),
]


def leaves():
    with Image.open(SOURCES / "ApprovedCombined.webp") as source:
        crop = source.convert("RGBA").crop((55, 1736, 205, 1855))
    mask = Image.new("L", (crop.width * SCALE, crop.height * SCALE))
    ImageDraw.Draw(mask).polygon([(x * SCALE, y * SCALE) for x, y in LEAVES_OUTLINE], fill=255)
    crop.putalpha(mask.resize(crop.size, Image.Resampling.LANCZOS))
    return crop.resize((304, 240), Image.Resampling.LANCZOS)


def save(image, name):
    red, green, blue, alpha = image.split()
    visible = alpha.point(lambda value: 255 if value else 0)
    clean = Image.merge("RGBA", (ImageChops.multiply(red, visible),
                                 ImageChops.multiply(green, visible),
                                 ImageChops.multiply(blue, visible), alpha))
    clean.save(OUTPUT / f"{name}.png", optimize=True)


def sprig():
    with Image.open(SOURCES / "CornerSprig.webp") as source:
        crop = source.convert("RGBA").crop((40, 35, 1240, 1210))
    # Длинные побеги остаются видны за пределами перекрываемого рамкой корня.
    return ImageEnhance.Brightness(crop.resize((256, 256), Image.Resampling.LANCZOS)).enhance(0.82)


def bracket(master):
    # Единый мастер содержит крюк И кольцо: взаимное перекрытие не собирается
    # из двух независимых спрайтов. Пластина начинается в x38 логических pt.
    source = master.crop((178, 110, 1395, 954))
    result = Image.new("RGBA", (44 * SCALE, 30 * SCALE))
    for left, right, target_left, target_right in ((0, 1068, 0, 152), (1068, 1217, 152, 176)):
        fragment = source.crop((left, 0, right, 844)).resize(
            (target_right - target_left, 30 * SCALE), Image.Resampling.LANCZOS)
        result.paste(fragment, (target_left, 0))
    return ImageEnhance.Brightness(result).enhance(0.78)


def lantern():
    with Image.open(SOURCES / "LanternOriginal.png") as source:
        original = source.convert("RGBA")
    if original.size != (52, 99):
        raise ValueError("LanternOriginal must retain its 52×99 source canvas")
    result = Image.new("RGBA", original.size)
    result.paste(original.crop((10, 25, 52, 99)), (10, 25))
    result.paste(original.crop((0, 34, 10, 99)), (0, 34))
    return result


def main():
    with Image.open(SOURCES / "LinkedBracket.webp") as source:
        suspension = source.convert("RGBA")
    assets = {
        "LivingSidebarSprig": sprig(),
        "LivingSidebarLeaves": leaves(),
        "LivingHangingLantern": lantern(),
        "LivingLanternBracket": bracket(suspension),
    }
    for name, image in assets.items():
        save(image, name)
        print(f"{name}.png: {image.width}×{image.height} RGBA")


if __name__ == "__main__":
    main()
