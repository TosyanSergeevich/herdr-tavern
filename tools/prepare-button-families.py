#!/usr/bin/env python3
"""Подготовка трёх одобренных материалов: Pillow, без генератора при сборке."""
from collections import deque
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "resources/Textures/Sources/ButtonFamilies"
OUTPUT = ROOT / "resources/Textures"
ASSETS = [
    ("ButtonNavigation", "a-sheet.webp", (40, 776, 494, 899)),
    ("ButtonPrimary", "b-sheet.webp", (56, 84, 540, 232)),
    ("ButtonTool", "c-sheet.webp", (38, 319, 493, 414)),
    ("ButtonToolIcon", "c-sheet.webp", (151, 478, 372, 693)),
]


def extract(image):
    image = image.convert("RGB")
    width, height = image.size
    pixels = image.load()
    corners = [pixels[0, 0], pixels[width-1, 0], pixels[0, height-1], pixels[width-1, height-1]]
    background = tuple(sum(p[c] for p in corners) // 4 for c in range(3))
    outside = set()
    queue = deque([(x, y) for x in range(width) for y in (0, height-1)] +
                  [(x, y) for y in range(height) for x in (0, width-1)])
    while queue:
        x, y = queue.popleft()
        if (x, y) in outside or not (0 <= x < width and 0 <= y < height):
            continue
        if max(abs(pixels[x, y][c] - background[c]) for c in range(3)) > 20:
            continue
        outside.add((x, y))
        queue.extend(((x-1, y), (x+1, y), (x, y-1), (x, y+1)))
    # Внутренние тёмные участки остаются непрозрачными: удаляется лишь связный фон.
    mask = Image.new("L", image.size, 255)
    alpha = mask.load()
    for point in outside:
        alpha[point] = 0
    # Единичные артефакты мастера не должны создавать плавающие непрозрачные точки.
    remaining = {(x, y) for y in range(height) for x in range(width) if alpha[x, y]}
    largest = set()
    while remaining:
        seed = remaining.pop()
        component = {seed}
        queue = deque([seed])
        while queue:
            x, y = queue.popleft()
            for neighbor in ((x-1, y), (x+1, y), (x, y-1), (x, y+1)):
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    component.add(neighbor)
                    queue.append(neighbor)
        if len(component) > len(largest):
            largest = component
    mask = Image.new("L", image.size, 0)
    # У всех четырёх мастеров выпуклый силуэт. Оболочка сохраняет скругления,
    # но не превращает тёмную фактуру и бороздки у кромки в прозрачные щели.
    def cross(origin, a, b):
        return (a[0]-origin[0]) * (b[1]-origin[1]) - (a[1]-origin[1]) * (b[0]-origin[0])
    points = sorted(largest)
    halves = []
    for ordered in (points, reversed(points)):
        half = []
        for point in ordered:
            while len(half) >= 2 and cross(half[-2], half[-1], point) <= 0:
                half.pop()
            half.append(point)
        halves.extend(half[:-1])
    ImageDraw.Draw(mask).polygon(halves, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(0.45))
    result = image.convert("RGBA")
    result.putalpha(mask)
    bounds = mask.getbbox()
    if bounds is None:
        raise ValueError("Не удалось выделить кнопку")
    result = result.crop(bounds)
    # Прозрачное поле исключает срез сглаженной кромки при растяжении.
    padded = Image.new("RGBA", (result.width+4, result.height+4))
    padded.paste(result, (2, 2))
    return padded


def main():
    for name, source, box in ASSETS:
        image = extract(Image.open(SOURCES / source).crop(box))
        image.save(OUTPUT / (name + ".png"))
        assert image.getchannel("A").getextrema() == (0, 255)
        print(name, image.size)


if __name__ == "__main__":
    main()
