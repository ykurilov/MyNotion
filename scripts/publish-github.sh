#!/bin/sh
# Выкладывает main в открытый репозиторий github.com/ykurilov/MyNotion.
# Снимки экрана настоящего Notion (specs/**/notion-*) в открытую историю не попадают:
# копия проекта каждый раз чистится одинаково, поэтому хэши коммитов совпадают и push идёт без перезаписи.
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/mynotion-publish.XXXXXX)
git clone -q --no-local --branch main --single-branch "$src" "$work"
cd "$work"
git filter-repo --force --invert-paths \
  --path-glob 'specs/*/notion-*' --path-glob 'specs/*/*/notion-*' --path-glob 'specs/*/*/*/notion-*' >/dev/null
if git log --name-only --format= | grep -qi '/notion-[^/]*\.\(png\|jpe\?g\)$'; then
  echo "снимки Notion остались в истории — выкладка остановлена" >&2; exit 1
fi
gitleaks git --no-banner --redact . >/dev/null
git push -q https://github.com/ykurilov/MyNotion.git main:main
echo "выложено: https://github.com/ykurilov/MyNotion ($(git rev-parse --short HEAD))"
rm -rf "$work"
