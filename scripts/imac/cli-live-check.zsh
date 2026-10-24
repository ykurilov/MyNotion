#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка команды `mynotion` на Release (005, T026).
#   1. установка `scripts/install-cli.sh` в папки сборки (HOME подменён: домашняя папка iMac не меняется);
#   2. приложение закрыто → `mynotion app status` поднимает его в фоне: фокус не уходит, ответ ≤ 4 с;
#   3. `mynotion page tree` → `not_implemented` (код выхода 4); права сокета 0600;
#   4. память и процессор в покое с открытым сокетом против сборки 004 (CLI_BASE — папка исходников 004 на iMac);
#   5. базы (этап 4): `db rows` на «Задачах» 10 000 эталона 004 ≤ 150 мс; шаг 7 сценария A и снимок окна с той же базой.
# Итоги — в build/cli-live/summary.txt.
set -uo pipefail
zmodload zsh/datetime  # EPOCHREALTIME
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/cli-live
rm -rf $out; mkdir -p $out
summary=$out/summary.txt
failed=0
note() { print -r -- "$*" | tee -a $summary; }
check() { if eval "$2"; then note "✓ $1"; else note "✗ $1"; failed=1; fi }

pgrep -x MyNotion >/dev/null && fail "На iMac уже запущен MyNotion: проверка «приложение закрыто» невозможна."

build_app Release build/cli-live-dd > $out/build.log 2>&1 || { tail -30 $out/build.log; fail "Сборка Release не прошла"; }
check "в пакете есть Contents/Helpers/mynotion" "[[ -x $APP/Contents/Helpers/mynotion ]]"

# Установка тем же скриптом, что на основном Mac, но в папки сборки.
home=$out/home
mkdir -p $home
HOME=$home zsh scripts/install-cli.sh --app $APP --target $out/apps > $out/install.log 2>&1
check "install-cli.sh: приложение, ссылка, скилл" \
  "[[ -x $out/apps/MyNotion.app/Contents/Helpers/mynotion && -L $home/.local/bin/mynotion && -f $home/.agents/skills/mynotion/SKILL.md ]]"
mynotion=$home/.local/bin/mynotion

# База по умолчанию: на iMac её не было — после проверки папка удаляется, как не было.
support=$HOME/Library/Application\ Support/MyNotion
had_support=0; [[ -d $support ]] && had_support=1
socket=$support/control.sock

front_name() { lsappinfo info -only name $(lsappinfo front) 2>/dev/null | head -1 }
front_before=$(front_name)
started=$EPOCHREALTIME
$mynotion app status --agent cli-live-check > $out/app-status.json 2> $out/app-status.err
status_rc=$?
elapsed=$(( EPOCHREALTIME - started ))
front_after=$(front_name)
note "app status из закрытого: $(printf '%.2f' $elapsed) с, код $status_rc"
check "app status ответил ok" "grep -q '\"ok\":true' $out/app-status.json"
check "запуск командой ≤ 4 с" "(( elapsed <= 4 ))"
check "фокус не ушёл (передним осталось $front_before)" "[[ \"$front_before\" == \"$front_after\" ]]"

$mynotion page tree > $out/page-tree.json 2>&1
tree_rc=$?
check "page tree → not_implemented, код 4" "(( tree_rc == 4 )) && grep -q '\"code\":\"not_implemented\"' $out/page-tree.json"
check "права сокета 0600" "[[ \$(stat -f %Lp \"$socket\") == 600 ]]"
$mynotion --help > $out/help.txt 2>&1
check "справка без приложения" "grep -q 'Группы:' $out/help.txt"

# Покой: процессор с открытым сокетом без команд.
pid=$(pgrep -x MyNotion | head -1)
sleep 10
cpu=$(top -l 5 -s 1 -pid $pid -stats cpu | awk '/^[0-9.]+$/ { last = $1 } END { print last + 0 }')
note "процессор в покое: $cpu %"
footprint_mb() { footprint -p $1 2>/dev/null | awk '/phys_footprint:/ { v = $2; u = $3 } END { if (u == "KB") v /= 1024; if (u == "GB") v *= 1024; printf "%.1f", v }' }
note "память в покое (005, база по умолчанию): $(footprint_mb $pid) МБ"
kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
# SIGTERM обходит обычный выход: файл сокета остаётся, но слушать некому — команда видит, что приложение закрыто.
$mynotion app status --no-launch > $out/after-kill.json 2>&1
after_rc=$?
check "после выхода: --no-launch → app_not_running, код 5" "(( after_rc == 5 )) && grep -q '\"code\":\"app_not_running\"' $out/after-kill.json"
(( had_support )) || rm -rf $support

# Память против 004: та же пустая база, обычный запуск, 10 с покоя — по три запуска каждой сборки.
measure() {
  local app=$1 label=$2 db pid values=()
  for i in 1 2 3; do
    db=$out/db-$label-$i; rm -rf $db; mkdir -p $db
    open -g -n $app --args --database $db/MyNotion.sqlite
    for t in {1..50}; do pid=$(pgrep -nf "$app/Contents/MacOS/MyNotion") && break; sleep 0.2; done
    sleep 10
    values+=($(footprint_mb $pid))
    kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
  done
  note "память в покое $label: ${(j: / :)values} МБ"
}
wait_for_quiet_indexer >> $summary
measure $APP 005
if [[ -n ${CLI_BASE:-} && -d $CLI_BASE ]]; then
  (cd $CLI_BASE && xcodegen generate -q && xcodebuild -scheme MyNotion -configuration Release -derivedDataPath build/cli-base-dd \
    -jobs $JOBS build -quiet) > $out/base-build.log 2>&1 || { tail -20 $out/base-build.log; fail "Сборка 004 не прошла"; }
  measure $CLI_BASE/build/cli-base-dd/Build/Products/Release/MyNotion.app 004
fi

# Этап 4 (базы): замер `db rows` первой страницы на «Задачах» 10 000 строк (эталон 004) и шаг 7 сценария A со снимком
# окна. База — в коротком пути: сокет рядом с ней.
dbdir=/tmp/mynotion-cli-db; rm -rf $dbdir; mkdir -p $dbdir
mn() { $mynotion "$@" --socket $dbdir/control.sock --no-launch --agent cli-live-check }
ok_json() { grep -q '"ok":true' $1 }
open -g -n $APP --args --database $dbdir/MyNotion.sqlite --generate-004-sample
for t in {1..600}; do [[ -S $dbdir/control.sock ]] && break; sleep 0.2; done
mn app status > $out/db-app-status.json 2>&1
check "приложение с эталоном 004 отвечает" "ok_json $out/db-app-status.json"
wait_for_quiet_indexer >> $summary

mn db rows Задачи --limit 50 > $out/db-rows-tasks.json 2>&1
check "db rows Задачи: 50 строк из 10 000" \
  "ok_json $out/db-rows-tasks.json && grep -q '\"total\":10000' $out/db-rows-tasks.json"
times=()
for i in {1..20}; do
  started=$EPOCHREALTIME
  mn db rows Задачи --limit 50 > /dev/null 2>&1
  times+=($(( (EPOCHREALTIME - started) * 1000 )))
done
sorted=(${(on)times})
note "db rows Задачи --limit 50, 20 вызовов (с запуском клиента): медиана $(printf '%.0f' $sorted[10]) мс, p95 $(printf '%.0f' $sorted[19]) мс"
check "db rows первой страницы ≤ 150 мс (медиана)" "(( sorted[10] <= 150 ))"

# Шаг 7: база страницей под «Обзором», статус, дата, 50 строк пачкой, вид с фильтром, сортировкой и группой.
mn db create --parent Обзор --title Спринт > $out/db-create.json 2>&1
mn db prop add Обзор/Спринт --name Статус --type status > $out/db-prop-status.json 2>&1
mn db prop add Обзор/Спринт --name Срок --type date > $out/db-prop-date.json 2>&1
mn db prop add Обзор/Спринт --name Часы --type number > $out/db-prop-hours.json 2>&1
statuses=(Не\ начато В\ работе Готово)
{
  print -n '['
  for i in {1..50}; do
    (( i > 1 )) && print -n ','
    printf '{"Название":"Задача %02d","Статус":"%s","Срок":"2026-11-%02d","Часы":%d}' \
      $i "$statuses[$(( i % 3 + 1 ))]" $(( (i * 7) % 28 + 1 )) $(( i % 5 ))
  done
  print ']'
} > $out/rows.json
mn db row add Обзор/Спринт --rows $out/rows.json > $out/db-row-add.json 2>&1
mn db view update Обзор/Спринт Таблица --filter '{"property":"Часы","operator":"greaterThan","value":0}' \
  --sort '[{"property":"Срок","direction":"ascending"}]' --group '{"property":"Статус"}' > $out/db-view-update.json 2>&1
mn db rows Обзор/Спринт --view Таблица --limit 1000 > $out/db-rows-sprint.json 2>&1
check "шаг 7: создание, свойства, 50 строк, вид — ok" \
  "ok_json $out/db-create.json && ok_json $out/db-prop-status.json && ok_json $out/db-prop-date.json && ok_json $out/db-prop-hours.json \
   && ok_json $out/db-row-add.json && grep -q '\"count\":50' $out/db-row-add.json && ok_json $out/db-view-update.json"
check "шаг 7: db rows — 40 строк (Часы > 0) в группах статуса" \
  "ok_json $out/db-rows-sprint.json && grep -q '\"total\":40' $out/db-rows-sprint.json"
mn --human db rows Обзор/Спринт --view Таблица --limit 1000 > $out/db-rows-sprint.txt 2>&1
pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion")
kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
# Окно с той же базой: открыта «Спринт», снимок после отрисовки (порядок и группы сверяются с db-rows-sprint.txt).
open -W -g -n $APP --args --database $dbdir/MyNotion.sqlite --relations-demo --relations-demo-open Спринт \
  --window-snapshot $out/db-sprint-window.png
check "снимок окна «Спринт»" "[[ -s $out/db-sprint-window.png ]]"

(( failed )) && note "ИТОГ: есть провалы" || note "ИТОГ: всё прошло"
exit $failed
