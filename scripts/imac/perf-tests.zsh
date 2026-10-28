#!/bin/zsh
# Группа замеров скорости: в обычном прогоне её нет, включается переменной MYNOTION_PERF.
# Полные объёмы (эталонная база 1000 страниц / 100 000 блоков, 10 000 строк, 20 000 блоков, 3000 детей,
# 1000 чередований) и бюджеты времени — тесты с «Performance» или «FullScale» в имени.
# Модули — по одному (одна дорожка): замеры не делят машину друг с другом.
#
#   scripts/imac/perf-tests.zsh          # пакет, затем UI-бюджеты (меню «/» SC-101, клавиатура SC-006)
#   scripts/imac/perf-tests.zsh package  # только пакет
#   scripts/imac/perf-tests.zsh ui       # только UI
set -eu
cd ${0:A:h:h:h}
what=${1:-all}
rc=0
if [[ $what == (all|package) ]]; then
  imac-run --no-fallback --wait 1800 --no-setup -- \
    'MYNOTION_PERF=1 MYNOTION_TEST_LANES=1 zsh scripts/test-package.zsh --filter "Performance|FullScale"' || rc=$?
fi
if [[ $what == (all|ui) ]]; then
  scripts/imac/run-on-imac.sh lock -- \
    'TEST_RUNNER_MYNOTION_PERF=1 zsh scripts/imac/on-imac.sh uitest -only-testing:UITests/SlashMenuSpeedTests -only-testing:UITests/KeyboardOnlyPageTests' || rc=$?
fi
exit $rc
