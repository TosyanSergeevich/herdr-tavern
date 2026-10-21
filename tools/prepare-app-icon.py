#!/usr/bin/env python3
"""Подготовка AppIcon.png и AppIcon.icns из утверждённого концепта (Pillow)."""
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "resources/Icons/Sources/TavernSign.webp"
OUTPUT = ROOT / "resources/Icons"


def main():
    image = Image.open(SOURCE).convert("RGB")
    # Удаляется только связанное с границей светлое поле, не светлый знак >_.
    candidate = image.point(lambda value: 255 if value >= 200 else 0)
    channels = candidate.split()
    mask = ImageChops.darker(ImageChops.darker(channels[0], channels[1]), channels[2])
    ImageDraw.floodfill(mask, (0, 0), 128)
    alpha = mask.point(lambda value: 0 if value == 128 else 255)
    # Убираем смешанную со светлым полем кромку, сглаживаем только альфа-канал.
    alpha = alpha.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.GaussianBlur(0.45))
    icon = image.convert("RGBA")
    icon.putalpha(alpha)
    # Сохраняем исходные поля вокруг плитки: размер символа в Dock не завышается.
    icon = icon.resize((1024, 1024), Image.Resampling.LANCZOS)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    icon.save(OUTPUT / "AppIcon.png")
    with tempfile.TemporaryDirectory(prefix="tavern-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                icon.resize((size * scale, size * scale), Image.Resampling.LANCZOS).save(
                    iconset / f"icon_{size}x{size}{suffix}.png"
                )
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(OUTPUT / "AppIcon.icns")],
            check=True,
        )
    print("Созданы resources/Icons/AppIcon.png и AppIcon.icns")


if __name__ == "__main__":
    main()
