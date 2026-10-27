#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка ссылок `mynotion://page/<id>`.
#   scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/page-link-live-check.zsh
# Приложение со своей базой; страница создаётся командой, её `link` открывается системным `open`, как щелчок в чате.
# Итоги и снимки — build/page-link-live/.
set -uo pipefail
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/page-link-live
rm -rf $out; mkdir -p $out
summary=$out/summary.txt
failed=0
note() { print -r -- "$*" | tee -a $summary; }
check() { if eval "$2"; then note "✓ $1"; else note "✗ $1"; failed=1; fi }

build_app Debug build/imac-dd > $out/build.log 2>&1 || { tail -30 $out/build.log; fail "Сборка не прошла"; }
check "в Info.plist есть схема mynotion" "plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw $APP/Contents/Info.plist | grep -qx mynotion"
pgrep -f "$APP/Contents/MacOS/MyNotion" >/dev/null && fail "Эта сборка MyNotion уже запущена."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $APP
handler=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.URLWithString("mynotion://page/x")).path.js' 2>&1)
check "macOS отдаёт ссылки mynotion:// этой сборке ($handler)" "[[ \"$handler\" == \"$APP\" ]]"
# Ссылка — именно этой сборке: на iMac могут работать другие копии MyNotion (проверки других агентов).
open_link() { open -a $APP "$1" }

cli=$APP/Contents/Helpers/mynotion
dbdir=/tmp/mynotion-page-link; rm -rf $dbdir; mkdir -p $dbdir
mn() { $cli "$@" --socket $dbdir/control.sock --no-launch --agent page-link-check }
py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" $1 2>/dev/null }
run() { local name=$1; shift; mn "$@" > $out/$name.json 2>&1; }
shot() { ~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$out/$1.png\"}" > $out/$1.shot.json 2>&1 }
# Выбранная вкладка переднего окна показывает страницу $1 (ждём до 5 с).
shows() {
  local t
  for t in {1..25}; do
    run state window state
    [[ $(py $out/state.json '[t["pageId"] for w in d["data"]["windows"] if w["front"] for t in w["tabs"] if t["selected"]][0]') == $1 ]] && return 0
    sleep 0.2
  done
  return 1
}

open -g -n $APP --args --database $dbdir/MyNotion.sqlite --generate-visual-sample
for t in {1..600}; do [[ -S $dbdir/control.sock ]] && break; sleep 0.2; done
for t in {1..100}; do run state-0 window state; [[ $(py $out/state-0.json 'len(d["data"]["windows"])') == 1 ]] && break; sleep 0.2; done
sample=$(py $out/state-0.json 'd["data"]["windows"][0]["tabs"][0]["pageId"]')

print -l "# Ссылки" "" {1..60}". строка" > $out/long.md
run page page create --title Ссылка-А --markdown $out/long.md
page=$(py $out/page.json 'd["data"]["page"]["id"]')
link=$(py $out/page.json 'd["data"]["page"]["link"]')
check "page create: в ответе link mynotion://page/<id>" "[[ -n \"$page\" && \"$link\" == mynotion://page/$page ]]"

# Терминал впереди: щелчок по ссылке выводит MyNotion вперёд и открывает страницу новой вкладкой.
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
open_link "$link"
check "open <link>: передняя вкладка — «Ссылка-А»" "shows $page"
check "open <link>: вкладок две (образец остался)" "[[ \$(py $out/state.json '[len(w[\"tabs\"]) for w in d[\"data\"][\"windows\"] if w[\"front\"]][0]') == 2 ]]"
# Впереди именно эта копия: на iMac бывают запущены другие MyNotion с тем же bundle id.
app_pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion")
se() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to $1" 2>&1 }
is_front() { local t; for t in {1..15}; do [[ $(se 'get frontmost') == true ]] && return 0; sleep 0.2; done; return 1 }
front_app() { osascript -e 'tell application "System Events" to get {name, unix id} of first process whose frontmost is true' 2>&1 }
# Впереди loginwindow (экран iMac заблокирован) — вперёд не выходит никто, проверять нечего.
front_check() {
  if is_front; then note "✓ $1"
  elif [[ $(front_app) == *loginwindow* ]]; then note "– $1: пропущено, впереди служебный loginwindow (экран iMac заблокирован)"
  else note "✗ $1 (впереди $(front_app))"; failed=1; fi
}
front_check "open <link>: эта копия MyNotion впереди"
sleep 0.5; shot page-link

# Та же ссылка ещё раз — новой вкладки нет.
open_link "$link"; sleep 1
check "повтор ссылки: вкладок по-прежнему две" "shows $page && [[ \$(py $out/state.json '[len(w[\"tabs\"]) for w in d[\"data\"][\"windows\"] if w[\"front\"]][0]') == 2 ]]"

# Ссылка на блок: прокрутка к последней строке.
run read page read $page --format json
block=$(py $out/read.json 'd["data"]["blocks"][-1]["id"]')
open_link "$link#$block"; sleep 1.5
check "ссылка на блок: страница та же" "shows $page"
front_check "ссылка на блок: эта копия впереди"
shot block-link

# Кнопка-цепочка в верхней строке: ссылка в буфере, галочка на кнопке и плашка «Ссылка скопирована».
# Щелчок и снимки — по окну этой копии через cua-driver: окна других копий могут его закрывать.
cua=~/.local/bin/cua-driver
win_id=$($cua call list_windows '{}' | python3 -c "import json,sys; print([w['window_id'] for w in json.load(sys.stdin)['windows'] if w['pid']==$app_pid and w['layer']==0 and w['title']][0])")
# Снимок окна и элементы по запросу $1 в $out/$2.json, окно — $out/$2.png.
win_state() { $cua call get_window_state "{\"pid\":$app_pid,\"window_id\":$win_id,\"query\":\"$1\",\"screenshot_out_file\":\"$out/$2.png\"}" > $out/$2.json 2>&1 }
# Окно целиком под чужим не перерисовывается: сдвигаем его в угол экрана.
se 'set frontmost to true' >/dev/null; se 'set position of window 1 to {0, 30}' >/dev/null; sleep 0.5
win_state 'Копировать ссылку' before-copy
button=$(py $out/before-copy.json '[e["element_index"] for e in d["elements"] if e.get("label")=="Копировать ссылку"][0]')
snapshot=$(py $out/before-copy.json 'd["snapshot_id"]')
print -n "" | pbcopy
$cua call click "{\"pid\":$app_pid,\"window_id\":$win_id,\"element_index\":$button,\"snapshot_id\":\"$snapshot\"}" > $out/click.json 2>&1
check "кнопка «Копировать ссылку» нажата" "[[ -n \"$button\" ]] && ! grep -q '\"isError\": *true' $out/click.json"
sleep 0.3
# Сначала снимок без обхода элементов: плашка живёт полторы секунды.
$cua call get_window_state "{\"pid\":$app_pid,\"window_id\":$win_id,\"max_elements\":1,\"screenshot_out_file\":\"$out/copied.png\"}" > /dev/null 2>&1
check "в буфере ссылка на страницу ($(pbpaste))" "[[ \"\$(pbpaste)\" == \"$link\" ]]"
# ⌘L — то же самое.
sleep 2; print -n "" | pbcopy
se 'set frontmost to true' >/dev/null; se 'keystroke "l" using command down' >/dev/null
$cua call get_window_state "{\"pid\":$app_pid,\"window_id\":$win_id,\"include_screenshot\":false,\"max_depth\":12,\"query\":\"Ссылка скопирована\"}" > $out/after-copy.json 2>&1
check "⌘L кладёт ссылку в буфер" "[[ \"\$(pbpaste)\" == \"$link\" ]]"
check "плашка «Ссылка скопирована» на экране" "grep -q 'Ссылка скопирована' $out/after-copy.json"

# Страница в корзине: объяснение в окне, приложение живо.
run trash page trash $page
open_link "$link"; sleep 1.5
shot trashed-link
check "страница в корзине: приложение не упало" "pgrep -f \"$APP/Contents/MacOS/MyNotion\" >/dev/null"
pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion")
alert_text() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get value of static texts of window 1" 2>&1 }
alert_text > $out/alert.txt
check "страница в корзине: показано окно с объяснением ($(tr '\n' ' ' < $out/alert.txt))" "grep -q корзин $out/alert.txt"

kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
rm -rf $dbdir

(( failed )) && note "ИТОГ ссылок: есть провалы" || note "ИТОГ ссылок: всё прошло"
exit $failed
