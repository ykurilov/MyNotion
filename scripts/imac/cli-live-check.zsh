#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка команды `mynotion` на Release (005, T026, T036).
#   1. установка `scripts/install-cli.sh` в папки сборки (HOME подменён: домашняя папка iMac не меняется);
#   2. приложение закрыто → `mynotion page tree --depth 1` поднимает его в фоне: фокус не уходит, ответ ≤ 4 с (сценарий A, шаг 1);
#   3. страницы (шаги 2, 3, 11): `page create` с `meeting.md`, `page read` — тот же Markdown, корзина, `trash delete` без
#      `--force` → `force_required`; снимок окна; права сокета 0600;
#   4. память и процессор в покое с открытым сокетом против прошлой сборки (CLI_BASE — папка её исходников на iMac, CLI_BASE_LABEL — подпись, по умолчанию 004).
#   5. базы (этап 4): `db rows` на «Задачах» 10 000 эталона 004 ≤ 150 мс; шаг 7 сценария A и снимок окна с той же базой.
#   6. окно (этап 6): `cli-live-window.zsh` — open, вкладки, назад/вперёд, фокус без `--activate`, снимок шага 4 сценария A.
#   7. блоки и обложка (этап 3, шаги 5–6 сценария A): правка командой видна в окне ≤ 1 с, курсор в другом блоке на месте,
#      снимки экрана build/cli-live/blocks-*.png. CLI_LIVE_ONLY=blocks — только этот шаг (после установки).
#   8. импорт, выгрузка, синхронизация (этап 7): `cli-live-transfer.zsh` — шаг 12 сценария A, импорт фикстуры Notion.
# Итоги — в build/cli-live/summary.txt (окно — ещё и в build/cli-live-window/).
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

# Шаги 5–6 сценария A. Страница — «богатый» образец; блоки строятся самими командами (id приходят в ответах).
# Курсор: страница — один текстовый вид, место курсора читается через AX (ax-text-probe.swift); у блока с курсором
# окружающий текст до и после правок должен совпасть. Видимость правки ≤ 1 с — по появлению текста в окне.
# Снимок экрана: screencapture по SSH не видит экран, а cua-driver (приложение с правом записи экрана) видит.
desktop_shot() {
  local driver=$HOME/.local/bin/cua-driver
  open -g -a $HOME/Applications/CuaDriver.app
  for t in {1..20}; do $driver status > /dev/null 2>&1 && break; sleep 0.5; done
  $driver call get_desktop_state "{\"screenshot_out_file\": \"$1\"}" > /dev/null 2>&1 || note "снимок $1 не получился"
}

live_blocks() {
  local dir; dir=$(mktemp -d /tmp/mnlb.XXXX)   # короткий путь: сокет длиннее 100 байт уходит в хэш-имя
  local probe=$out/ax-text-probe pid id_a id_b id_t id_p1 id_p2 before after waited
  swiftc -O scripts/imac/ax-text-probe.swift -o $probe > $out/probe-build.log 2>&1 || { tail -5 $out/probe-build.log; fail "ax-text-probe не собрался"; }
  open -g -n $APP --args --database $dir/MyNotion.sqlite --generate-rich-sample
  for t in {1..100}; do pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion") && break; sleep 0.2; done
  local cli=(env MYNOTION_SOCKET=$dir/control.sock $mynotion --agent cli-live-check)
  for t in {1..100}; do $cli app status > /dev/null 2>&1 && break; sleep 0.2; done
  osascript -e 'tell application "MyNotion" to activate'
  check "блоки: окно страницы открылось" "$probe $pid wait 'Блок 1' 20 > /dev/null"
  json_get() { python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k]
print(str(d).lower() if isinstance(d, bool) else d)' "$@" }
  insert() { $cli block insert current "$@" > $out/insert.json 2>&1; json_get $out/insert.json data.block.id }
  id_a=$(insert --kind paragraph --text "Курсор Юрия здесь" --first)
  id_b=$(insert --kind paragraph --text "Вторая строка" --after $id_a)
  id_t=$(insert --kind checkbox --text "Задача проверки" --after $id_b)
  id_p1=$(insert --kind bulletItem --text "Пункт один" --after $id_t)
  id_p2=$(insert --kind bulletItem --text "Пункт два" --after $id_p1)
  check "блоки: пять блоков собраны командами" "[[ -n $id_a && -n $id_b && -n $id_t && -n $id_p1 && -n $id_p2 ]] && $probe $pid wait 'Пункт два' 3 > /dev/null"

  # Юрий пишет в пункте «Пункт один»; агент правит соседние блоки.
  $probe $pid set "Пункт один" 6 > /dev/null
  before=$($probe $pid get | sed 's/^loc=[0-9]* //')
  note "курсор до правок: $before"

  $cli block insert current --kind callout --text "Итог" --after $id_b > $out/step5-insert.json 2>&1
  waited=$($probe $pid wait "Итог" 3)
  note "вставка выноски видна в окне: $waited"
  check "правка (вставка) видна ≤ 1 с" "[[ \"$waited\" == ms=* ]] && (( \${waited#ms=} <= 1000 ))"
  $cli block check $id_t > $out/step5-check.json 2>&1
  check "block check: задача отмечена" "[[ \$(json_get $out/step5-check.json data.block.checked) == true ]]"
  $cli block indent $id_p2 > $out/step5-indent.json 2>&1
  check "block indent: пункт сдвинут" "[[ \$(json_get $out/step5-indent.json data.changed) == true && \$(json_get $out/step5-indent.json data.block.indent) == 1 ]]"
  sleep 1
  desktop_shot $out/blocks-after-edits.png
  after=$($probe $pid get | sed 's/^loc=[0-9]* //')
  note "курсор после правок: $after"
  check "курсор в «Пункт один» не сбит правками соседей" "[[ \"$before\" == \"$after\" ]]"

  $cli page icon current --emoji 🚀 > $out/step6-icon.json 2>&1
  after=$($probe $pid get | sed 's/^loc=[0-9]* //')
  note "курсор после иконки: $after"
  waited=$($probe $pid wait "🚀" 3)
  note "иконка видна в окне: $waited"
  check "иконка видна ≤ 1 с" "[[ \"$waited\" == ms=* ]] && (( \${waited#ms=} <= 1000 ))"
  $cli page cover current --gallery gradients_3 > $out/step6-cover.json 2>&1
  check "page cover: обложка поставлена" "grep -q '\"ok\":true' $out/step6-cover.json"
  sleep 1
  desktop_shot $out/blocks-with-icon-cover.png
  after=$($probe $pid get | sed 's/^loc=[0-9]* //')
  note "курсор после обложки: $after"
  check "курсор на месте и после иконки с обложкой" "[[ \"$before\" == \"$after\" ]]"

  $cli block delete $id_b > $out/step5-delete.json 2>&1
  check "block delete: ответ ok" "grep -q '\"ok\":true' $out/step5-delete.json"
  kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
  rm -rf $dir
}

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
if [[ ${CLI_LIVE_ONLY:-} == blocks ]]; then
  live_blocks
  (( failed )) && note "ИТОГ: есть провалы" || note "ИТОГ: всё прошло"
  exit $failed
fi

# База по умолчанию: на iMac её не было — после проверки папка удаляется, как не было.
support=$HOME/Library/Application\ Support/MyNotion
had_support=0; [[ -d $support ]] && had_support=1
socket=$support/control.sock

front_name() { lsappinfo info -only name $(lsappinfo front) 2>/dev/null | head -1 }
front_before=$(front_name)
started=$EPOCHREALTIME
$mynotion page tree --depth 1 --agent cli-live-check > $out/page-tree.json 2> $out/page-tree.err
tree_rc=$?
elapsed=$(( EPOCHREALTIME - started ))
front_after=$(front_name)
note "page tree из закрытого: $(printf '%.2f' $elapsed) с, код $tree_rc"
check "шаг 1: page tree ответил ok с деревом" "(( tree_rc == 0 )) && grep -q '\"items\":' $out/page-tree.json"
check "запуск командой ≤ 4 с" "(( elapsed <= 4 ))"
check "фокус не ушёл (передним осталось $front_before)" "[[ \"$front_before\" == \"$front_after\" ]]"
$mynotion app status --agent cli-live-check > $out/app-status.json 2> $out/app-status.err
check "app status ответил ok" "grep -q '\"ok\":true' $out/app-status.json"

# Страницы (сценарий A, шаги 2, 3, 11). Поле ответа: json_field <файл> <путь через точку>.
json_field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); [v := v[k] for k in sys.argv[2].split(".")]; print(v)' $1 $2 }
export MYNOTION_AGENT=cli-live-check
$mynotion page create --title Проекты > $out/projects.json
plan_id=$($mynotion page create --title "План проекта" > $out/plan.json && json_field $out/plan.json data.page.id)
# В фикстуре ссылка на страницу с условным id — здесь она ведёт на настоящую «План проекта».
sed "s/00000000-0000-4000-8000-0000000000aa/$plan_id/" Packages/MyNotionKit/Tests/PageMarkdownTests/Fixtures/meeting.md > $out/meeting.md
$mynotion page create --parent Проекты --title "Встреча 24.10" --markdown $out/meeting.md > $out/create.json 2>&1
check "шаг 2: page create с meeting.md → ok, data.page.id" "grep -q '\"ok\":true' $out/create.json"
meeting_id=$(json_field $out/create.json data.page.id)
$mynotion page read $meeting_id > $out/read.json 2>&1
json_field $out/read.json data.markdown > $out/read.md
check "шаг 3: page read — тот же Markdown, что meeting.md" \
  "python3 -c 'import sys; a, b = (open(f).read().strip() for f in sys.argv[1:]); sys.exit(a != b)' $out/meeting.md $out/read.md"
diff $out/meeting.md $out/read.md > $out/read.diff
$mynotion page tree Проекты > $out/projects-tree.json
check "встреча в дереве под «Проекты»" "grep -q 'Встреча 24.10' $out/projects-tree.json"

# Снимок окна: страница в дереве боковой панели.
pid=$(pgrep -x MyNotion | head -1)
window=$(~/.local/bin/cua-driver call list_windows "{\"pid\":$pid}" | python3 -c 'import json,sys; ws=json.load(sys.stdin)["windows"]; print(max(ws, key=lambda w: w["bounds"]["width"]*w["bounds"]["height"])["window_id"] if ws else "")')
if [[ -n $window ]]; then
  ~/.local/bin/cua-driver call get_window_state "{\"pid\":$pid,\"window_id\":$window,\"screenshot_out_file\":\"$out/window.png\"}" > $out/window.json 2>&1
fi
check "снимок окна снят" "[[ -s $out/window.png ]]"

$mynotion page trash $meeting_id > $out/trash.json 2>&1
check "шаг 11: page trash → inTrash" "grep -q '\"inTrash\":true' $out/trash.json"
$mynotion page restore $meeting_id > $out/restore.json 2>&1
check "шаг 11: page restore → ok" "grep -q '\"ok\":true' $out/restore.json && grep -q '\"inTrash\":false' $out/restore.json"
$mynotion page trash $meeting_id > /dev/null 2>&1
$mynotion trash delete $meeting_id > $out/delete.json 2>&1
check "шаг 11: trash delete без --force → force_required" "grep -q '\"code\":\"force_required\"' $out/delete.json"
$mynotion page restore $meeting_id > /dev/null 2>&1
check "после отказа страница цела" "$mynotion page read $meeting_id > /dev/null 2>&1"
unset MYNOTION_AGENT
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
    -jobs $JOBS build -quiet) > $out/base-build.log 2>&1 || { tail -20 $out/base-build.log; fail "Сборка ${CLI_BASE_LABEL:-004} не прошла"; }
  measure $CLI_BASE/build/cli-base-dd/Build/Products/Release/MyNotion.app ${CLI_BASE_LABEL:-004}
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

# Этап 6 (окно): отдельный сценарий на той же сборке.
APP=$APP zsh ${0:A:h}/cli-live-window.zsh | tee -a $summary
(( ${pipestatus[1]} )) && failed=1

# Этап 5 (US4): шаги 9–10 сценария A и примеры references/library.md на своей базе. Агент — e2e.
libdir=/tmp/mynotion-cli-lib; rm -rf $libdir; mkdir -p $libdir
ml() { $mynotion "$@" --socket $libdir/control.sock --no-launch --agent e2e }
open -g -n $APP --args --database $libdir/MyNotion.sqlite
for t in {1..300}; do [[ -S $libdir/control.sock ]] && break; sleep 0.2; done
ml page create --title Проекты > /dev/null 2>&1
ml page create --parent Проекты --title "Встреча 24.10" --markdown $out/meeting.md > $out/lib-create.json 2>&1
lib_id=$(json_field $out/lib-create.json data.page.id)
# Эталон — страница до правки агента: ссылка «План проекта» ведёт в другую базу и здесь читается текстом.
ml page read $lib_id > $out/lib-read-before.json 2>&1
json_field $out/lib-read-before.json data.markdown > $out/lib-read-before.md
print -r -- "испорчено агентом" | ml page write $lib_id --markdown - > $out/lib-write.json 2>&1
ml history list $lib_id > $out/lib-history.json 2>&1
check "шаг 9: history list — версия agent: e2e" "ok_json $out/lib-history.json && grep -q '\"agent\":\"e2e\"' $out/lib-history.json"
version_id=$(python3 -c 'import json,sys; print(next(v["id"] for v in json.load(open(sys.argv[1]))["data"]["items"] if v["agent"] == "e2e"))' $out/lib-history.json)
ml history show $lib_id $version_id > $out/lib-show.json 2>&1
ml history restore $lib_id $version_id > $out/lib-restore.json 2>&1
ml page read $lib_id > $out/lib-read.json 2>&1
json_field $out/lib-read.json data.markdown > $out/lib-read.md
check "шаг 9: history restore — страница как до правки агента" \
  "ok_json $out/lib-restore.json && python3 -c 'import sys; a, b = (open(f).read().strip() for f in sys.argv[1:]); sys.exit(a != b)' $out/lib-read-before.md $out/lib-read.md"
ml batch --file =(print -r -- "[{\"command\":\"history.restore\",\"args\":{\"page\":\"$lib_id\",\"version\":\"$version_id\"}}]") > $out/lib-batch.json 2>&1
check "history restore в пакете → not_batchable" "grep -q '\"code\":\"not_batchable\"' $out/lib-batch.json"
ml search Встреча > $out/lib-search.json 2>&1
found_path() { python3 -c 'import json,sys; sys.exit(not any(i["id"] == sys.argv[2] and i["path"] == ["Проекты", "Встреча 24.10"] for i in json.load(open(sys.argv[1]))["data"]["items"]))' $1 $2 }
check "шаг 10: search «Встреча» — страница с путём «Проекты / Встреча 24.10»" "found_path $out/lib-search.json $lib_id"
ml favorites add $lib_id > $out/lib-fav.json 2>&1
ml favorites list > $out/lib-fav-list.json 2>&1
ml recents > $out/lib-recents.json 2>&1
check "шаг 10: favorites add/list, recents" \
  "grep -q '\"isFavorite\":true' $out/lib-fav.json && grep -q \"$lib_id\" $out/lib-fav-list.json && ok_json $out/lib-recents.json"
# Остальные примеры library.md по порядку.
ml page create --title "Шаблон встречи" --markdown =(print -r -- "## Повестка") > /dev/null 2>&1
ml favorites move $lib_id --index 0 > $out/lib-fav-move.json 2>&1
ml search "план запуска" --limit 5 > $out/lib-search2.json 2>&1
ml template mark "Шаблон встречи" > $out/lib-tmark.json 2>&1
ml template list > $out/lib-tlist.json 2>&1
ml page create --parent Проекты --title "Встреча 31.10" --template "Шаблон встречи" > $out/lib-from-template.json 2>&1
ml template unmark "Шаблон встречи" > $out/lib-tunmark.json 2>&1
ml history show $lib_id $version_id --format json > $out/lib-show-json.json 2>&1
check "примеры: избранное, поиск, шаблоны, history show" \
  "ok_json $out/lib-fav-move.json && ok_json $out/lib-search2.json && grep -q '\"isTemplate\":true' $out/lib-tmark.json \
   && grep -q 'Шаблон встречи' $out/lib-tlist.json && ok_json $out/lib-from-template.json && ok_json $out/lib-tunmark.json \
   && ok_json $out/lib-show.json && grep -q '\"blocks\":' $out/lib-show-json.json"
cp Packages/MyNotionKit/Tests/NotionImportTests/Fixtures/notion-export/synthetic/Проекты*/отчёт.pdf $libdir/отчёт.pdf
cp Packages/MyNotionKit/Tests/NotionImportTests/Fixtures/notion-export/synthetic/Проекты*/MyNotion*/Идеи*/schema.png $libdir/схема.png
head -c 4096 /dev/urandom > $libdir/ролик.mp4
ml attachment add $lib_id --file $libdir/отчёт.pdf > $out/lib-att-pdf.json 2>&1
ml attachment add $lib_id --file $libdir/схема.png > $out/lib-att-png.json 2>&1
ml attachment add $lib_id --file $libdir/ролик.mp4 > $out/lib-att-mp4.json 2>&1
ml attachment add $lib_id --file $libdir/схема.png --as file > $out/lib-att-as.json 2>&1
ml attachment add $lib_id --file $libdir/нет.pdf > $out/lib-att-missing.json 2>&1
check "attachment add: файл, картинка, видео, --as, нет файла" \
  "grep -q '\"kind\":\"file\"' $out/lib-att-pdf.json && grep -q '\"kind\":\"image\"' $out/lib-att-png.json \
   && grep -q '\"kind\":\"video\"' $out/lib-att-mp4.json && grep -q '\"kind\":\"file\"' $out/lib-att-as.json \
   && grep -q '\"code\":\"file_not_found\"' $out/lib-att-missing.json"
ml db create --parent Проекты --title Задачи > /dev/null 2>&1
ml db prop add Проекты/Задачи --name Файлы --type files > /dev/null 2>&1
ml db row add Проекты/Задачи --values '{"Название":"Отчёт"}' > /dev/null 2>&1
ml attachment add Проекты/Задачи Отчёт Файлы --file $libdir/отчёт.pdf > $out/lib-att-cell.json 2>&1
check "attachment add в ячейку «Файлы»" "ok_json $out/lib-att-cell.json && grep -q '\"Файлы\":\\[{\"attachmentId\"' $out/lib-att-cell.json"
ml attachment list $lib_id > $out/lib-att-list.json 2>&1
png_id=$(json_field $out/lib-att-png.json data.attachment.id)
mkdir -p $libdir/выгрузка
ml attachment get $png_id --to $libdir/выгрузка > $out/lib-att-get.json 2>&1
ml attachment get $png_id --to $libdir/копия.png > $out/lib-att-get2.json 2>&1
check "attachment list и get: байты совпадают" \
  "grep -q \"$png_id\" $out/lib-att-list.json && cmp -s $libdir/схема.png $libdir/выгрузка/схема.png && cmp -s $libdir/схема.png $libdir/копия.png"
ml favorites remove $lib_id > $out/lib-fav-remove.json 2>&1
check "favorites remove" "grep -q '\"isFavorite\":false' $out/lib-fav-remove.json"
ml favorites add $lib_id > /dev/null 2>&1
pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion")
kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
open -W -g -n $APP --args --database $libdir/MyNotion.sqlite --window-snapshot $out/lib-window.png
check "снимок окна: избранное и вложения" "[[ -s $out/lib-window.png ]]"

live_blocks
# Этап 7 (импорт, выгрузка, синхронизация): отдельный сценарий на той же сборке.
APP=$APP zsh ${0:A:h}/cli-live-transfer.zsh | tee -a $summary
(( ${pipestatus[1]} )) && failed=1

(( failed )) && note "ИТОГ: есть провалы" || note "ИТОГ: всё прошло"
exit $failed
