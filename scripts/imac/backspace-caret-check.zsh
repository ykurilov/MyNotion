#!/bin/zsh
# Живая проверка на iMac: после ⌫ курсор и подсказка пустого пункта стоят на его строке, а не на строке заголовка выше
# (баг Юрия 25.10.2026). Настоящие нажатия ⌫ (key-press-probe), курсор ставится через «Универсальный доступ» (ax-text-probe).
#
#   scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/backspace-caret-check.zsh [--skip-build]
#
# Сценарии: (а) пустой последний пункт под заголовком — ⌫ по одному; (б) стирание текста пункта зажатой ⌫;
# (в) ⌫ в начале непустого пункта под заголовком, ниже есть абзац; (г) то же, пункт — последний блок;
# (д) зажатая ⌫ стирает пункт в середине списка и поднимается выше. Снимки экрана — build/backspace-caret/<сценарий>-<шаг>-<1..3>.png.
set -uo pipefail
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/backspace-caret
rm -rf $out; mkdir -p $out

if [[ ${1:-} != --skip-build ]]; then
  build_app Release build/backspace-dd > $out/build.log 2>&1 || { tail -30 $out/build.log; fail "Сборка Release не прошла"; }
fi
APP=$WORK/build/backspace-dd/Build/Products/Release/MyNotion.app
[[ -d $APP ]] || fail "Нет сборки $APP"
for tool in ax-text-probe key-press-probe; do
  swiftc -O scripts/imac/$tool.swift -o $out/$tool 2> $out/$tool-build.log || fail "$tool не собрался: $(cat $out/$tool-build.log)"
done

dbdir=/tmp/mynotion-backspace; rm -rf $dbdir; mkdir -p $dbdir
quit_ours() { pkill -f "$APP/Contents/MacOS/MyNotion" 2>/dev/null || true; }
quit_ours
mn() { $APP/Contents/Helpers/mynotion "$@" --socket $dbdir/control.sock --no-launch --agent backspace-check }
# Курсор мигает (полсекунды горит, полсекунды нет): три снимка подряд, хоть на одном он виден.
shot() {
  print -r -- "-- $1: $($out/ax-text-probe $pid get)" >> $out/steps.log
  caffeinate -u -t 1
  for i in 1 2 3; do
    ~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$out/$1-$i.png\"}" > $out/$1-$i.shot.json 2>&1
    sleep 0.2
  done
}

open -n $APP --args --database $dbdir/MyNotion.sqlite --appearance light "-NSWindow Frame pages-AppWindow-1" "156 76 1200 800 0 0 1512 952 "
for t in {1..300}; do [[ -S $dbdir/control.sock ]] && break; sleep 0.2; done
[[ -S $dbdir/control.sock ]] || fail "MyNotion не открыл сокет управления"
pid=$(pgrep -f "$APP/Contents/MacOS/MyNotion" | head -1)

# Страница из бага: два заголовка, список из пяти пунктов, под вторым заголовком — пункт «last» и, если задано, абзац.
page() {
  local name=$1 last=$2 below=${3:-}
  {
    print -r -- "## Нейропродавец"
    print -r -- "За 5 недель создайте нейропродавца, который сам находит вам клиентов в мессенджерах"
    print -r -- "### Чему вы научитесь:"
    print -r -- "- Запускать своего нейропродавца без программирования"
    print -r -- "- Объяснять нейропродавцу, как говорить с людьми"
    print -r -- "- Находить клиентов для своего дела в мессенджерах"
    print -r -- "- Настраивать нейропродавца так, чтобы он передавал только готовых купить"
    print -r -- "- Делать нейропродавцов на заказ для компаний"
    print -r -- "### Что вы сделаете:"
    print -r -- "- $last"
    [[ -n $below ]] && print -r -- "$below"
  } > $out/$name.md
  mn page create --title "Проверка $name" --markdown $out/$name.md > $out/$name-create.json 2>&1
  local id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['data']['page']['id'])" $out/$name-create.json)
  mn open $id --activate > $out/$name-open.json 2>&1
  sleep 1.5
}
caret() { $out/ax-text-probe $pid set "$1" $2 >> $out/steps.log; sleep 0.4; }
backspace() { $out/key-press-probe $pid 51 $1 ${2:-35} >> $out/steps.log; sleep 0.6; }

print -r -- "== а: пустой последний пункт, ⌫ по одному" >> $out/steps.log
page a "Ж"
caret "Ж" 1; backspace 1; shot a-1-empty
backspace 1; shot a-2-paragraph
backspace 1; shot a-3-merged

print -r -- "== б: стирание пункта зажатой ⌫" >> $out/steps.log
page b "абвгд"
caret "абвгд" 5; backspace 5; shot b-1-erased
backspace 3; shot b-2-held-on

print -r -- "== в: начало непустого пункта, ниже абзац" >> $out/steps.log
page c "абв" "Ниже"
caret "абв" 0; backspace 1; shot c-1-paragraph
backspace 1; shot c-2-merged

print -r -- "== г: начало непустого последнего пункта" >> $out/steps.log
page d "абв"
caret "абв" 0; backspace 1; shot d-1-paragraph
backspace 1; shot d-2-merged

print -r -- "== д: пункт в середине списка, зажатая ⌫" >> $out/steps.log
page e "абв"
caret "Находить клиентов для своего дела в мессенджерах" 48; backspace 48; shot e-1-erased
backspace 2; shot e-2-merged

quit_ours
print -r -- "Снимки: $out"
ls $out/*.png
