#!/bin/zsh
# Снимки MyNotionPhone в симуляторе iPhone 17 Pro (iOS 26.5) на iMac — в build/iphone-shots/:
# пустое состояние, подключение, дерево, страница, дерево в тёмной теме. Каждый снимок — со своей чистой базой.
# Приложение — из сборки scripts/imac/iphone-build.zsh.
set -euo pipefail
source ${0:A:h}/lib.sh
boot_iphone_simulator

SHOTS=$WORK/build/iphone-shots
rm -rf $SHOTS; mkdir -p $SHOTS
BUNDLE=cloud.kurilov.mynotion.ios

# shot <имя> <тема light|dark> <флаги приложения…>
shot() {
  local name=$1 appearance=$2; shift 2
  local db=$(mktemp -d /tmp/mn-phone-shot.XXXXXX)/notes.sqlite
  xcrun simctl ui $DEVICE appearance $appearance
  xcrun simctl launch --terminate-running-process $DEVICE $BUNDLE --database $db "$@" >/dev/null
  sleep 4
  xcrun simctl io $DEVICE screenshot $SHOTS/$name.png >/dev/null 2>&1
  xcrun simctl terminate $DEVICE $BUNDLE 2>/dev/null || true
  rm -rf ${db:h}
}

shot empty light
shot connect light --screen connect
shot tree light --sample-pages
shot page light --sample-pages --screen 'page:Заметки на неделю'
shot tree-dark dark --sample-pages
xcrun simctl ui $DEVICE appearance light
print -- "[MyNotion/iMac] iPhone: снимки в build/iphone-shots ($(ls $SHOTS | wc -l | tr -d ' ') шт.)"
