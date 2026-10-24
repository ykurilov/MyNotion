#!/bin/zsh
# Эталон: ставит ли Chrome I-beam и руку, когда его окно позади другого приложения. Настоящая мышь, как в
# real-cursor-check.zsh. Выполняется НА iMac внутри `imac-run --gui`:
#
#   imac-run --gui --no-fallback --no-setup --wait 3000 --fetch build/real-cursor -- 'zsh scripts/imac/background-cursor-reference.zsh [chrome|notion]'
#
# chrome — со своим пустым профилем в build/: профиль и окна Юрия не трогаются; страница: текст и ссылка.
# notion — приложение Notion как есть; уже запущенное не закрывается (мышь только водится над окном).
# Журнал — build/real-cursor/foreign-<приложение>.log.
set -euo pipefail
source ${0:A:h}/lib.sh

OUT=$WORK/build/real-cursor
PROFILE=$WORK/build/chrome-cursor-profile
CHROME="/Applications/Google Chrome.app"
target=${1:-chrome}
mkdir -p $OUT
require_gui_session
[[ -d $CHROME ]] || fail "На iMac нет Google Chrome"
swiftc -O -swift-version 5 scripts/imac/real-cursor-probe.swift -o $OUT/real-cursor-probe 2> $OUT/probe-build.log \
  || fail "probe не собрался: $(cat $OUT/probe-build.log)"

# Сверху сплошной текст, снизу ссылка во всю ширину: probe берёт точки на 40 % и 85 % высоты окна.
cat > $OUT/background-cursor-page.html <<'HTML'
<!doctype html><meta charset="utf-8">
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; font: 48px/1 -apple-system; }
  #text { height: 65vh; overflow: hidden; word-break: break-all; }
  #link { display: block; height: 35vh; background: #dde; }
</style>
<div id="text"></div><a id="link" href="#">ссылка во всю ширину</a>
<script>document.getElementById('text').textContent = 'ШЖМШЖМ'.repeat(800)</script>
HTML

if [[ $target == notion ]]; then
  NOTION=/Applications/Notion.app
  quit_ours() { true; }
  pgrep -xq Notion || quit_ours() { pkill -x Notion 2>/dev/null || true; }
  open $NOTION  # у запущенного без окон — открывает окно
  pid=""
  for _ in {1..50}; do pid=$(pgrep -x Notion | head -1 || true); [[ -n $pid ]] && break; sleep 0.2; done
  [[ -n $pid ]] || fail "Notion не запустился"
  sleep 8
else
  # Гасим только свой Chrome (по папке профиля): чужие окна Chrome на iMac не трогаем.
  quit_ours() { pkill -f -- "--user-data-dir=$PROFILE" 2>/dev/null || true; }
  quit_ours; sleep 1
  rm -rf $PROFILE
  open -na $CHROME --args --user-data-dir=$PROFILE --no-first-run --no-default-browser-check --new-window \
    --window-position=150,120 --window-size=1740,1000 file://$OUT/background-cursor-page.html
  pid=""
  for _ in {1..50}; do
    pid=$(pgrep -f -- "Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=$PROFILE" | head -1 || true)
    [[ -n $pid ]] && break; sleep 0.2
  done
  [[ -n $pid ]] || fail "Chrome не запустился"
  sleep 4
fi
rc=0
log=$OUT/foreign-$target.log
rm -f $log
$OUT/real-cursor-probe $pid $log foreign >/dev/null || rc=$?
[[ -f $log ]] && grep -E '^(ok|BAD|FAIL|RESULT|inactive|window)' $log
quit_ours
exit $rc
