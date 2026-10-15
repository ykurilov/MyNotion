#!/usr/bin/env python3
"""Собирает список эмодзи для окна выбора иконки (FR-034) из данных Unicode и CLDR.

Источники (скачиваются в папку-аргумент, в проект не кладутся):
  https://unicode.org/Public/17.0.0/emoji/emoji-test.txt                       -> emoji-test.txt
  cldr-json (48.x): cldr-annotations-full/annotations/{ru,en}/annotations.json  -> ann-ru.json, ann-en.json
                    cldr-annotations-derived-full/annotationsDerived/{ru,en}/annotations.json -> der-ru.json, der-en.json

Запуск: python3 -I scripts/emoji/build-emoji-data.py <папка с источниками>
Пишет Packages/MyNotionKit/Sources/EmojiPicker/Resources/emoji.tsv:
  раздел <TAB> эмодзи <TAB> имя en <TAB> слова en через «|» <TAB> имя ru <TAB> слова ru через «|»
Только полные (fully-qualified) эмодзи без вариантов тона кожи; «Component» не входит.
"""
import json
import pathlib
import sys

SECTIONS = {
    "Smileys & Emotion": "people", "People & Body": "people", "Animals & Nature": "nature",
    "Food & Drink": "food", "Activities": "activities", "Travel & Places": "travel",
    "Objects": "objects", "Symbols": "symbols", "Flags": "flags",
}
SKIN_TONES = {chr(c) for c in range(0x1F3FB, 0x1F400)}


def annotations(folder, language):
    merged = {}
    for name, key in ((f"ann-{language}.json", "annotations"), (f"der-{language}.json", "annotationsDerived")):
        for emoji, entry in json.load(open(folder / name, encoding="utf-8"))[key]["annotations"].items():
            merged[emoji.replace("️", "")] = (entry.get("tts", [""])[0], entry.get("default", []))
    return merged


def clean(text):
    return text.replace("\t", " ").replace("|", "/").strip()


def main():
    folder = pathlib.Path(sys.argv[1])
    ru, en = annotations(folder, "ru"), annotations(folder, "en")
    rows, section = [], None
    for line in open(folder / "emoji-test.txt", encoding="utf-8"):
        if line.startswith("# group:"):
            section = SECTIONS.get(line.split(":", 1)[1].strip())
            continue
        if not section or line.startswith("#") or "; fully-qualified" not in line:
            continue
        emoji = line.split("#", 1)[1].split()[0]
        if SKIN_TONES & set(emoji):
            continue
        unicode_name = line.split("#", 1)[1].strip().split(" ", 2)[2]
        key = emoji.replace("️", "")
        en_name, en_words = en.get(key, (unicode_name, []))
        ru_name, ru_words = ru.get(key, ("", []))
        rows.append("\t".join([section, emoji, clean(en_name or unicode_name), "|".join(map(clean, en_words)),
                               clean(ru_name), "|".join(map(clean, ru_words))]))
    out = pathlib.Path(__file__).resolve().parents[2] / "Packages/MyNotionKit/Sources/EmojiPicker/Resources/emoji.tsv"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"{len(rows)} эмодзи -> {out}")


main()
