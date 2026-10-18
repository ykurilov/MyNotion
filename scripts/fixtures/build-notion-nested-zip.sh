#!/bin/zsh
# Собирает synthetic-nested.zip из папки synthetic/ так, как Notion отдаёт большую выгрузку:
# внешний ZIP, внутри части «ExportBlock-…-Part-N.zip» с деревом страниц (T083).
set -euo pipefail
fixtures="$(cd "$(dirname "$0")/../../Packages/MyNotionKit/Tests/NotionImportTests/Fixtures/notion-export" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/part1" "$work/part2" "$work/outer"
cd "$fixtures/synthetic"
for entry in Проекты*; do cp -R "$entry" "$work/part1/"; done
cp Дневник*.md "$work/part2/"
id=0b6f2c1e-4d7a-4f3e-9a51-6c2d8e9f0a13
(cd "$work/part1" && ditto -c -k --norsrc --noextattr . "$work/outer/ExportBlock-$id-Part-1.zip")
(cd "$work/part2" && ditto -c -k --norsrc --noextattr . "$work/outer/ExportBlock-$id-Part-2.zip")
rm -f "$fixtures/synthetic-nested.zip"
(cd "$work/outer" && ditto -c -k --norsrc --noextattr . "$fixtures/synthetic-nested.zip")
echo "$fixtures/synthetic-nested.zip"
