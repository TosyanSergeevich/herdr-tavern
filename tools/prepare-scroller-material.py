#!/usr/bin/env python3
"""Бронза скролл-баров из утверждённого концепта A; требуется Pillow."""
from pathlib import Path
from PIL import Image, ImageEnhance, ImageOps

ROOT = Path(__file__).resolve().parents[1]
TEXTURES = ROOT / "resources/Textures"
SOURCE = TEXTURES / "Sources/ScrollbarBronzeConcept.webp"


def prepare():
    with Image.open(SOURCE) as concept:
        # Внутренность образца бронзы: без рамки, надписей и запечённой фаски.
        patch = concept.crop((1226, 794, 1330, 898)).convert("RGB")
    patch = patch.resize((64, 64), Image.Resampling.LANCZOS)
    patch = ImageEnhance.Color(patch).enhance(0.55)
    patch = ImageEnhance.Brightness(patch).enhance(0.78)
    # Отражённые соседи дают точное замыкание всех четырёх сторон.
    # Размер тайла фиксирован; длина ползунка не растягивает фактуру.
    tile = Image.new("RGB", (128, 128))
    tile.paste(patch, (0, 0))
    tile.paste(ImageOps.mirror(patch), (64, 0))
    tile.paste(ImageOps.flip(patch), (0, 64))
    tile.paste(ImageOps.flip(ImageOps.mirror(patch)), (64, 64))
    tile.save(TEXTURES / "ScrollerBronze.png", optimize=True)


if __name__ == "__main__":
    prepare()
