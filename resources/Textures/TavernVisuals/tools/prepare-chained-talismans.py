#!/usr/bin/env python3
"""Подготовка runtime-талисманов и проушины (Python + Pillow).

Повторный запуск читает сохранённый sources/chained/talismans-chain-v1.webp.
Явный --concepts DIR заменяет только этот мастер побайтно; при замене нужно
отдельно актуализировать сведения об источниках и правах в NOTICE.
Контуры заданы в координатах листа 1536×1024; тёмные грани сохраняются.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "sources/chained"
OUT = ROOT / "chained"
MASTER = "talismans-chain-v1.webp"
SCALE = 0.435
BODY_SIZE = (128, 160)
BODY_PIVOT = (64, 12)
RESAMPLE = Image.Resampling.LANCZOS

# Обход внешнего края; отдельные внутренние просветы заданы явно ниже.
# Не используем предварительные chain-placement PNG: в них осталась древесина.
BODIES = {
    "progress": {
        "pivot": (168, 466),
        "outline": [(158,452),(168,452),(177,458),(181,471),(178,483),(173,487),(188,484),(211,475),(216,476),(239,580),(232,631),(245,639),(253,659),(244,696),(232,701),(224,690),(214,722),(199,742),(186,748),(178,772),(148,787),(126,769),(99,739),(92,706),(96,681),(85,687),(84,656),(82,624),(68,599),(67,592),(92,550),(100,553),(108,562),(109,537),(117,514),(121,501),(143,489),(162,484),(163,474)],
        "holes": [[(90,626),(97,630),(98,650),(91,670),(89,664)]],
    },
    "success": {
        "pivot": (469, 478),
        "outline": [(460,457),(469,454),(477,461),(479,477),(474,490),(490,491),(503,497),(507,505),(499,509),(517,519),(536,538),(553,565),(565,594),(572,624),(572,654),(566,684),(552,711),(532,732),(511,750),(490,761),(469,768),(444,766),(424,756),(410,748),(402,735),(392,726),(380,708),(373,691),(368,693),(363,673),(359,652),(359,631),(364,606),(374,584),(387,564),(403,545),(419,530),(425,521),(420,520),(421,507),(434,499),(454,492),(462,491),(464,481)],
        "holes": [[(374,696),(383,693),(394,686),(400,684),(399,691),(403,697),(411,700),(409,703),(399,700),(386,695)]],
    },
    "question": {
        "pivot": (765, 478),
        "outline": [(755,460),(763,460),(772,466),(775,481),(769,493),(789,488),(806,489),(824,495),(840,508),(851,527),(858,552),(857,572),(851,592),(837,610),(815,630),(798,648),(785,669),(783,681),(774,688),(761,688),(763,702),(777,711),(787,728),(789,743),(784,757),(773,768),(757,773),(738,770),(722,758),(715,745),(713,731),(719,715),(730,705),(742,700),(743,689),(727,687),(720,682),(721,661),(726,643),(738,626),(755,610),(772,596),(782,582),(787,566),(785,554),(778,548),(767,547),(753,553),(744,563),(739,577),(731,587),(721,589),(705,584),(688,576),(676,566),(679,550),(686,532),(697,516),(712,505),(731,496),(751,492),(760,491),(761,481)],
        "holes": [],
    },
    "error": {
        "pivot": (1066, 477),
        "outline": [(1055,460),(1063,457),(1070,463),(1075,478),(1071,488),(1087,483),(1093,492),(1090,503),(1118,528),(1136,550),(1149,548),(1160,560),(1164,582),(1169,612),(1166,636),(1177,643),(1174,664),(1169,684),(1159,690),(1149,715),(1127,741),(1103,761),(1076,785),(1050,777),(1024,764),(1000,747),(982,731),(974,715),(967,714),(970,701),(976,692),(967,667),(962,642),(960,613),(951,606),(949,598),(963,559),(970,551),(982,557),(998,535),(1022,514),(1023,503),(1044,494),(1059,489),(1060,479)],
        "holes": [],
    },
    "waiting": {
        "pivot": (1368, 485),
        "outline": [
            (1357,474),(1366,471),(1375,477),(1380,490),(1378,501),(1389,502),
            (1402,498),(1416,497),(1422,499),(1432,497),(1447,501),(1449,505),
            (1440,521),(1432,527),(1438,532),(1444,542),(1442,557),(1437,568),
            (1449,570),(1456,578),(1453,590),(1465,597),(1476,613),(1480,631),
            (1477,645),(1467,658),(1453,665),(1441,664),(1441,683),(1449,690),
            (1440,701),(1450,716),(1461,728),(1454,739),(1449,742),(1437,743),
            (1424,742),(1413,743),(1403,733),(1398,743),(1380,750),(1363,750),
            (1354,744),(1345,750),(1328,753),(1310,760),(1299,757),(1291,752),
            (1284,768),(1280,772),(1271,763),(1274,751),(1278,740),(1283,735),
            (1274,736),(1271,731),(1272,719),(1277,704),(1282,696),(1292,689),
            (1282,684),(1285,674),(1280,664),(1284,649),
            (1281,635),(1284,627),(1283,614),(1276,606),(1279,599),(1294,591),
            (1281,579),(1279,563),(1268,560),(1260,554),(1262,542),(1267,533),
            (1263,519),(1264,513),(1274,510),(1286,513),(1298,512),(1307,523),
            (1314,513),(1324,513),(1328,519),(1337,509),(1350,511),(1360,510),
            (1367,505),(1367,493)],
        "holes": [[(1434,583),(1440,579),(1445,581),(1444,590),(1437,590)]],
    },
}


def polygon_mask(size, points, holes=()):
    """4× coverage raster, no RGB key: сохраняет чёрные грани и трещины."""
    multiplier = 4
    mask = Image.new("L", (size[0] * multiplier, size[1] * multiplier))
    draw = ImageDraw.Draw(mask)
    draw.polygon([(round(x * multiplier), round(y * multiplier)) for x, y in points], fill=255)
    for hole in holes:
        draw.polygon([(round(x * multiplier), round(y * multiplier)) for x, y in hole], fill=0)
    return mask.resize(size, RESAMPLE)


def zero_outside(image):
    # Все ручные контуры лежат внутри canvas. Фильтр Lanczos может протянуть
    # слабый ringing до границы; резервируем гарантированно прозрачный guard
    # шириной 1 px, не перемещая pivot и не меняя содержательный силуэт.
    ImageDraw.Draw(image).rectangle(
        (0, 0, image.width - 1, image.height - 1), outline=(0, 0, 0, 0), width=1)
    pixels = [(r, g, b, a) if a else (0, 0, 0, 0) for r, g, b, a in image.getdata()]
    image.putdata(pixels)
    return image


def extracted_body(master, spec):
    points = spec["outline"]
    box = (min(x for x, y in points) - 3, min(y for x, y in points) - 3,
           max(x for x, y in points) + 4, max(y for x, y in points) + 4)
    local = lambda pts: [(x - box[0], y - box[1]) for x, y in pts]
    image = master.crop(box).convert("RGBA")
    image.putalpha(polygon_mask(image.size, local(points), [local(hole) for hole in spec["holes"]]))
    # Точная общая дробная координата pivot не зависит от округления размера crop.
    sx, sy = spec["pivot"]
    affine = (1 / SCALE, 0, sx - box[0] - BODY_PIVOT[0] / SCALE,
              0, 1 / SCALE, sy - box[1] - BODY_PIVOT[1] / SCALE)
    # Supersampling transform gives Lanczos quality while keeping exact pivot.
    high = image.convert("RGBa").transform((BODY_SIZE[0] * 2, BODY_SIZE[1] * 2),
        Image.Transform.AFFINE,
        (affine[0] / 2, 0, affine[2], 0, affine[4] / 2, affine[5]),
        resample=Image.Resampling.BICUBIC)
    return zero_outside(high.resize(BODY_SIZE, RESAMPLE).convert("RGBA"))


def extracted_mount(master):
    # Из исходной верхней проушины; ручная маска удаляет древесину и внутренний
    # просвет, а также всё нижнее звено. Функциональный mount, не угловая накладка.
    box = (130, 83, 202, 160)
    image = master.crop(box).convert("RGBA")
    mask = Image.new("L", (288, 308))
    draw = ImageDraw.Draw(mask)
    draw.ellipse((8, 8, 272, 292), fill=255)
    draw.ellipse((70, 75, 211, 225), fill=0)
    image.putalpha(mask.resize(image.size, RESAMPLE))
    image = image.convert("RGBa").resize((44, 47), RESAMPLE).convert("RGBA")
    canvas = Image.new("RGBA", (64, 64))
    canvas.alpha_composite(image, (10, 8))
    return zero_outside(canvas)


def save_sprite(image, asset_id):
    path = OUT / f"{asset_id}.png"
    image.save(path, format="PNG", optimize=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--concepts", type=Path)
    args = parser.parse_args()
    SOURCES.mkdir(parents=True, exist_ok=True); OUT.mkdir(parents=True, exist_ok=True)
    if args.concepts:
        # Источники сохраняются побайтно, включая встроенную provenance metadata.
        shutil.copy2(args.concepts / MASTER, SOURCES / MASTER)
    master = Image.open(SOURCES / MASTER).convert("RGB")
    if master.size != (1536, 1024):
        raise ValueError("Лист talismans-chain-v1.webp должен иметь размер 1536×1024")
    mount = extracted_mount(master)
    save_sprite(mount, "mount")
    for kind, spec in BODIES.items():
        image = extracted_body(master, spec)
        save_sprite(image, kind + "-body")
    print(f"Generated {len(BODIES) + 1} runtime RGBA sprites")


if __name__ == "__main__":
    main()
