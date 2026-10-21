#!/usr/bin/env python3
"""Подготовка runtime-закладки из сохранённого мастера. Нужны Pillow и NumPy."""
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
source = ROOT / 'sources/selection/bookmark-source.webp'
image = Image.open(source).convert('RGB').crop((395, 170, 668, 1290))
rgb = np.asarray(image, dtype=float)
alpha = np.uint8(np.clip((rgb.max(axis=2)-5)/20, 0, 1)*255)
image = image.convert('RGBA')
image.putalpha(Image.fromarray(alpha))
image = image.convert('RGBa').resize((128, 512), Image.Resampling.LANCZOS).convert('RGBA')
pixels = np.array(image)
pixels[:, :, :3] = np.clip(pixels[:, :, :3].astype(float) * 1.28, 0, 255).astype('uint8')
pixels[[0, -1], :, 3] = 0
pixels[:, [0, -1], 3] = 0
pixels[pixels[:, :, 3] == 0] = 0
image = Image.fromarray(pixels)
a = pixels[:, :, 3] > 0
luma = pixels[:, :, :3].mean(axis=2)
height = np.where(a, 190 + np.minimum(luma/15, 10), 0).astype('uint8')
material = np.zeros((512, 128, 3), dtype='uint8')
material[a] = (224, 0, 0)
destination = ROOT / 'sprites'
destination.mkdir(parents=True, exist_ok=True)
image.save(destination / 'bookmark.png')
Image.fromarray(height).save(destination / 'bookmark-height.png')
Image.fromarray(material).save(destination / 'bookmark-material.png')
