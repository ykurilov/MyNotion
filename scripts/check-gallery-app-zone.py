#!/usr/bin/env python3
"""Геометрия общего окна по снимкам галереи (`--ui-gallery <папка>`): пункты 3, 9, 12 отчёта
specs/001-core-pages-editor/ui-review/2026-10-15.md. Снимки @2x, все числа — в точках (pt).

Запуск: python3 scripts/check-gallery-app-zone.py /tmp/mynotion-gallery-app
Нужен Pillow. Код возврата 1 — есть расхождения.
"""
import sys
from pathlib import Path

from PIL import Image

SCALE = 2
TOP_BAR = 44
SIDEBAR = 270
# Снимок Notion visual-reference/notion-light-page.png (масштаб 1,37), от верха окна:
NOTION_ICON_CENTER = 178.5   # середина эмодзи 📘 (141,6–215,3)
NOTION_TITLE_CAP_TOP = 266.4  # верх букв названия
NOTION_PARAGRAPH_TOP = 334.3  # верх букв первого абзаца
TOLERANCE = 2.5


def load(folder, name):
    path = folder / name
    if not path.exists():
        return None
    return Image.open(path).convert("RGB")


def differs(a, b, threshold):
    return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) > threshold


def ink_bands(image, x0, x1, y0, y1, background, threshold=120):
    """Полосы строк (в pt), где между x0 и x1 есть пиксели, заметно отличные от фона."""
    px = image.load()
    bands, start = [], None
    for y in range(int(y0 * SCALE), int(y1 * SCALE)):
        ink = any(differs(px[x, y], background, threshold) for x in range(int(x0 * SCALE), int(x1 * SCALE)))
        if ink and start is None:
            start = y
        if not ink and start is not None:
            bands.append((start / SCALE, y / SCALE))
            start = None
    if start is not None:
        bands.append((start / SCALE, y1))
    return bands


def page_background(image):
    w, h = image.size
    return image.getpixel((w - 4, h // 2))


def check_scroll_edge(folder, failures):
    """№3: прокрученный текст не выглядывает обрезанной строкой из-под верхней полосы."""
    for theme in ("light", "dark"):
        image = load(folder, f"sample-bottom--1440x900--{theme}.png")
        if image is None:
            failures.append(f"№3: нет снимка sample-bottom {theme}")
            continue
        width = image.size[0] / SCALE
        bands = ink_bands(image, SIDEBAR + 2, width - 20, TOP_BAR, TOP_BAR + 4, page_background(image), threshold=45)
        if bands:
            failures.append(f"№3 {theme}: под верхней полосой видны обрывки строки на {bands}")


def check_breadcrumb(folder, failures):
    """№9: длинный путь не доходит до правого края окна ближе чем на 24."""
    for theme in ("light", "dark"):
        image = load(folder, f"long-breadcrumb--900x700--{theme}.png")
        if image is None:
            failures.append(f"№9: нет снимка long-breadcrumb {theme}")
            continue
        width, background = image.size[0] / SCALE, page_background(image)
        px = image.load()
        right = None
        for x in range(int(width * SCALE) - 1, int(SIDEBAR * SCALE), -1):
            if any(differs(px[x, y], background, 120) for y in range(8 * SCALE, (TOP_BAR - 8) * SCALE)):
                right = x / SCALE
                break
        if right is None:
            failures.append(f"№9 {theme}: путь не найден")
        elif width - right < 24:
            failures.append(f"№9 {theme}: путь кончается в {width - right:.1f} от правого края (нужно ≥ 24)")


def check_header_offsets(folder, failures):
    """№12: иконка, название и первый абзац на тех же высотах, что на снимке Notion."""
    for theme in ("light", "dark"):
        image = load(folder, f"sample-top--1440x900--{theme}.png")
        if image is None:
            failures.append(f"№12: нет снимка sample-top {theme}")
            continue
        width = image.size[0] / SCALE
        column_left = SIDEBAR + 1 + (width - SIDEBAR - 1 - 720) / 2
        bands = ink_bands(image, column_left, column_left + 720, TOP_BAR, 420, page_background(image))
        if len(bands) < 3:
            failures.append(f"№12 {theme}: не нашлись иконка, название и абзац: {bands}")
            continue
        icon, title, paragraph = bands[:3]
        for what, actual, expected in (
            ("середина иконки", (icon[0] + icon[1]) / 2, NOTION_ICON_CENTER),
            ("верх названия", title[0], NOTION_TITLE_CAP_TOP),
            ("верх первого абзаца", paragraph[0], NOTION_PARAGRAPH_TOP),
        ):
            if abs(actual - expected) > TOLERANCE:
                failures.append(f"№12 {theme}: {what} на {actual:.1f}, у Notion {expected:.1f}")


def main():
    folder = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/mynotion-gallery-app")
    failures = []
    check_scroll_edge(folder, failures)
    check_breadcrumb(folder, failures)
    check_header_offsets(folder, failures)
    for failure in failures:
        print("✘", failure)
    print("Геометрия окна:", "расхождений нет" if not failures else f"расхождений: {len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
