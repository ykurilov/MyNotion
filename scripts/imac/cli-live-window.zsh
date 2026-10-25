#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка команд окна на Release (005, этап 6, T062).
# Вызывается из `cli-live-check.zsh` (там же собрано приложение: APP в окружении) и работает сама:
#   scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/cli-live-window.zsh
# Шаги: окно, вкладки, назад/вперёд, окно по номеру, шаг 4 сценария A (`open --new-tab`, снимок), фокус не уходит без
# `--activate` (`lsappinfo front` до и после), `--activate` выводит приложение вперёд. Итоги — build/cli-live-window/.
set -uo pipefail
zmodload zsh/datetime  # EPOCHREALTIME
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/cli-live-window
rm -rf $out; mkdir -p $out
summary=$out/summary.txt
failed=0
note() { print -r -- "$*" | tee -a $summary; }
check() { if eval "$2"; then note "✓ $1"; else note "✗ $1"; failed=1; fi }

if [[ -z ${APP:-} || ! -d ${APP:-} ]]; then
  build_app Release build/cli-live-dd > $out/build.log 2>&1 || { tail -30 $out/build.log; fail "Сборка Release не прошла"; }
fi
cli=$APP/Contents/Helpers/mynotion
pgrep -x MyNotion >/dev/null && fail "На iMac уже запущен MyNotion: проверка окна невозможна."

dbdir=/tmp/mynotion-cli-win; rm -rf $dbdir; mkdir -p $dbdir
mn() { $cli "$@" --socket $dbdir/control.sock --no-launch --agent window-live-check }
# Значение из JSON ответа: py <файл> '<выражение над d>'
py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" $1 2>/dev/null }
# Переднее приложение — по номеру (ASN) из `lsappinfo front`: он не зависит от того, как печатается имя.
front_asn() { lsappinfo front 2>/dev/null }
front_name() { lsappinfo info -only name $(lsappinfo front) 2>/dev/null | head -1 | sed 's/ ASN:.*//' | tr -d '"' }
front_bundle() { lsappinfo info -only bundleid $(lsappinfo front) 2>/dev/null }
front_kept() { [[ $(front_asn) == $front_before ]] }
shot() { ~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$out/$1.png\"}" > $out/$1.shot.json 2>&1 }
run() { local name=$1; shift; mn "$@" > $out/$name.json 2>&1; }

front_before=$(front_asn)
open -g -n $APP --args --database $dbdir/MyNotion.sqlite --generate-visual-sample
for t in {1..600}; do [[ -S $dbdir/control.sock ]] && break; sleep 0.2; done
for t in {1..100}; do run state-0 window state; [[ $(py $out/state-0.json 'len(d["data"]["windows"])') == 1 ]] && break; sleep 0.2; done
front_app=$(front_name)
check "после запуска фокус не ушёл (передним осталось $front_app)" front_kept
check "window state: одно окно, одна вкладка, окно переднее" \
  "[[ \$(py $out/state-0.json 'len(d[\"data\"][\"windows\"])') == 1 && \$(py $out/state-0.json 'len(d[\"data\"][\"windows\"][0][\"tabs\"])') == 1 && \$(py $out/state-0.json 'd[\"data\"][\"windows\"][0][\"front\"]') == True ]]"
sample=$(py $out/state-0.json 'd["data"]["windows"][0]["tabs"][0]["pageId"]')

# Две страницы-базы под образцом: ими пользуются остальные шаги.
run page-a db create --parent $sample --title Окно-А
run page-b db create --parent $sample --title Окно-Б
page_a=$(py $out/page-a.json 'd["data"]["database"]["id"]')
page_b=$(py $out/page-b.json 'd["data"]["database"]["id"]')
check "две страницы для проверки созданы" "[[ -n \"$page_a\" && -n \"$page_b\" ]]"

# Шаг 4 сценария A: открыть новой вкладкой; фокус остаётся у терминала.
front_before=$(front_asn)
started=$EPOCHREALTIME
run open-new-tab open $page_a --new-tab
elapsed=$(( EPOCHREALTIME - started ))
sleep 1
shot step4-open-new-tab
check "open --new-tab: ok, 2 вкладки, выбрана вторая со страницей «Окно-А»" \
  "[[ \$(py $out/open-new-tab.json 'd[\"ok\"]') == True && \$(py $out/open-new-tab.json 'len(d[\"data\"][\"window\"][\"tabs\"])') == 2 \
    && \$(py $out/open-new-tab.json 'd[\"data\"][\"window\"][\"tabs\"][1][\"pageId\"]') == $page_a \
    && \$(py $out/open-new-tab.json 'd[\"data\"][\"window\"][\"tabs\"][1][\"selected\"]') == True ]]"
check "open --new-tab: фокус не ушёл (передним осталось $front_app)" front_kept
note "open --new-tab: $(printf '%.0f' $(( elapsed * 1000 ))) мс"

# Вкладки и переходы без смены переднего приложения.
run open-current open $page_b
check "open (в этой вкладке): вкладка 2 теперь «Окно-Б», можно назад" \
  "[[ \$(py $out/open-current.json 'd[\"data\"][\"window\"][\"tabs\"][1][\"pageId\"]') == $page_b && \$(py $out/open-current.json 'd[\"data\"][\"window\"][\"canGoBack\"]') == True ]]"
run nav-back nav back
check "nav back: вкладка 2 снова «Окно-А», можно вперёд" \
  "[[ \$(py $out/nav-back.json 'd[\"data\"][\"window\"][\"tabs\"][1][\"pageId\"]') == $page_a && \$(py $out/nav-back.json 'd[\"data\"][\"window\"][\"canGoForward\"]') == True ]]"
run nav-forward nav forward
check "nav forward: вкладка 2 — «Окно-Б»" "[[ \$(py $out/nav-forward.json 'd[\"data\"][\"window\"][\"tabs\"][1][\"pageId\"]') == $page_b ]]"
run nav-nowhere nav forward
check "nav forward без истории: ok, moved=false" "[[ \$(py $out/nav-nowhere.json 'd[\"ok\"]') == True && \$(py $out/nav-nowhere.json 'd[\"data\"][\"moved\"]') == False ]]"

run tab-new tab new
check "tab new: 3 вкладки, выбрана пустая (без страницы)" \
  "[[ \$(py $out/tab-new.json 'len(d[\"data\"][\"window\"][\"tabs\"])') == 3 && \$(py $out/tab-new.json 'd[\"data\"][\"window\"][\"tabs\"][2][\"pageId\"]') == None \
    && \$(py $out/tab-new.json 'd[\"data\"][\"window\"][\"tabs\"][2][\"selected\"]') == True ]]"
run tab-select tab select --tab 1
check "tab select --tab 1: выбрана первая" "[[ \$(py $out/tab-select.json 'd[\"data\"][\"window\"][\"tabs\"][0][\"selected\"]') == True ]]"
run tab-close tab close --tab 3
check "tab close --tab 3: осталось 2, можно вернуть" \
  "[[ \$(py $out/tab-close.json 'len(d[\"data\"][\"window\"][\"tabs\"])') == 2 && \$(py $out/tab-close.json 'd[\"data\"][\"window\"][\"canReopenTab\"]') == True ]]"
run tab-reopen tab reopen
check "tab reopen: снова 3 вкладки, выбрана вернувшаяся" \
  "[[ \$(py $out/tab-reopen.json 'len(d[\"data\"][\"window\"][\"tabs\"])') == 3 && \$(py $out/tab-reopen.json 'd[\"data\"][\"window\"][\"tabs\"][2][\"selected\"]') == True ]]"
run tab-bad tab select --tab 9
check "tab select --tab 9 → tab_not_found" "[[ \$(py $out/tab-bad.json 'd[\"error\"][\"code\"]') == tab_not_found ]]"
run window-bad tab new --window 7
check "tab new --window 7 → window_not_found" "[[ \$(py $out/window-bad.json 'd[\"error\"][\"code\"]') == window_not_found ]]"
check "команды вкладок: фокус не ушёл" front_kept

# Новое окно: появляется, страница в нём, фокус не ушёл.
run open-new-window open $page_a --new-window
sleep 1
shot open-new-window
check "open --new-window: окно 2 со страницей «Окно-А» и одной вкладкой" \
  "[[ \$(py $out/open-new-window.json 'd[\"data\"][\"window\"][\"index\"]') == 2 && \$(py $out/open-new-window.json 'd[\"data\"][\"window\"][\"tabs\"][0][\"pageId\"]') == $page_a \
    && \$(py $out/open-new-window.json 'len(d[\"data\"][\"window\"][\"tabs\"])') == 1 ]]"
check "open --new-window: фокус не ушёл (передним осталось $front_app)" front_kept
run state-2 window state
check "window state: два окна" "[[ \$(py $out/state-2.json 'len(d[\"data\"][\"windows\"])') == 2 ]]"
run tab-window-1 tab new --window 1
check "tab new --window 1: вкладка добавлена в окно 1 (4 вкладки)" "[[ \$(py $out/tab-window-1.json 'len(d[\"data\"][\"window\"][\"tabs\"])') == 4 ]]"

# Блок: страница-образец, любой её блок (id из базы, регистр не важен).
block=$(sqlite3 $dbdir/MyNotion.sqlite "SELECT id FROM block WHERE pageId = '$sample' AND isDeleted = 0 ORDER BY sortKey LIMIT 1 OFFSET 8" 2>/dev/null)
if [[ -n $block ]]; then
  run open-block open $sample --block $block
  check "open --block: ok" "[[ \$(py $out/open-block.json 'd[\"ok\"]') == True ]]"
else
  note "– open --block пропущен: блоков образца в базе не нашлось"
fi

# --activate: приложение выходит вперёд (только по просьбе).
run open-activate open $page_b --activate
is_front() { local t; for t in {1..15}; do [[ $(front_bundle) == *cloud.kurilov.mynotion* ]] && return 0; sleep 0.2; done; return 1 }
check "open --activate: приложение MyNotion стало передним" is_front
shot open-activate

pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion")
kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
rm -rf $dbdir

(( failed )) && note "ИТОГ окна: есть провалы" || note "ИТОГ окна: всё прошло"
exit $failed
