#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка импорта, выгрузки и синхронизации на Release
# (005, этап 7, T065). Вызывается из `cli-live-check.zsh` (APP в окружении) и работает сама:
#   scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/cli-live-transfer.zsh
# Шаги: шаг 12 сценария A (`export page` — те же файлы, что у этой ветки в выгрузке всего), `--no-children`, `export all`,
# `db export`, импорт фикстуры Notion с ходом и `--parent`, снимок окна, `sync status` и `sync now` без синхронизации
# (сервер синхронизации не нужен и не трогается). База — своя временная. Итоги — build/cli-live-transfer/.
set -uo pipefail
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/cli-live-transfer
rm -rf $out; mkdir -p $out
summary=$out/summary.txt
failed=0
note() { print -r -- "$*" | tee -a $summary; }
check() { if eval "$2"; then note "✓ $1"; else note "✗ $1"; failed=1; fi }

if [[ -z ${APP:-} || ! -d ${APP:-} ]]; then
  build_app Release build/cli-live-dd > $out/build.log 2>&1 || { tail -30 $out/build.log; fail "Сборка Release не прошла"; }
fi
cli=$APP/Contents/Helpers/mynotion
pgrep -x MyNotion >/dev/null && fail "На iMac уже запущен MyNotion: проверка импорта и выгрузки невозможна."

dbdir=/tmp/mynotion-cli-transfer; rm -rf $dbdir; mkdir -p $dbdir
mn() { $cli "$@" --socket $dbdir/control.sock --no-launch --agent transfer-live-check }
py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" $1 2>/dev/null }
run() { local name=$1; shift; mn "$@" > $out/$name.json 2> $out/$name.err; print $? > $out/$name.rc; }
ok() { [[ $(py $out/$1.json 'd["ok"]') == True ]] }

open -g -n $APP --args --database $dbdir/MyNotion.sqlite
for t in {1..600}; do [[ -S $dbdir/control.sock ]] && break; sleep 0.2; done

# Ветка для выгрузки: «Проекты» → «Встреча 24.10» (с подстраницей) и «Книга».
print -r -- $'Итоги встречи\n\n- [ ] Отправить план\n- [x] Созвониться\n\n**Важно:** срок — пятница' > $out/meeting.md
run projects page create --title Проекты
run meeting page create --parent Проекты --title "Встреча 24.10" --markdown $out/meeting.md
meeting=$(py $out/meeting.json 'd["data"]["page"]["id"]')
run detail page create --parent "Проекты/Встреча 24.10" --title Подробности --markdown $out/meeting.md
run book page create --parent Проекты --title Книга
check "страницы для выгрузки созданы" "ok projects && ok meeting && ok detail && ok book"

# Шаг 12: export page — файлы как у выгрузки из меню (та же ветка внутри `export all`).
mkdir -p $out/out $out/all
run export-page export page $meeting --to $out/out
check "шаг 12: export page → ok, 2 страницы" "ok export-page && [[ \$(py $out/export-page.json 'd[\"data\"][\"pageCount\"]') == 2 ]]"
page_folder=$(py $out/export-page.json 'd["data"]["folder"]')
run export-all export all --to $out/all
all_folder=$(py $out/export-all.json 'd["data"]["folder"]')
check "export all → ok, 4 страницы" "ok export-all && [[ \$(py $out/export-all.json 'd[\"data\"][\"pageCount\"]') == 4 ]]"
check "шаг 12: файлы export page = файлы этой ветки в выгрузке всего" \
  "diff -r \"$page_folder/Встреча 24.10\" \"$all_folder/Проекты/Встреча 24.10\" > $out/export.diff \
   && diff \"$page_folder/Встреча 24.10.md\" \"$all_folder/Проекты/Встреча 24.10.md\" >> $out/export.diff"
mkdir -p $out/alone
run export-alone export page $meeting --to $out/alone --no-children
alone_folder=$(py $out/export-alone.json 'd["data"]["folder"]')
check "export page --no-children: один файл" "ok export-alone && [[ \$(ls \"$alone_folder\" | wc -l | tr -d ' ') == 1 ]]"
run export-missing export page $meeting --to $out/нет-такой
check "export в несуществующую папку → file_not_found, код 3" \
  "[[ \$(py $out/export-missing.json 'd[\"error\"][\"code\"]') == file_not_found && \$(cat $out/export-missing.rc) == 3 ]]"

# db export: CSV, строки и схема базы.
run db-create db create --parent Проекты --title Задачи
print -r -- '[{"Название":"Позвонить"},{"Название":"Написать"}]' > $out/rows.json
run db-row db row add Задачи --rows $out/rows.json
mkdir -p $out/db
run db-export db export Задачи --to $out/db
db_folder=$(py $out/db-export.json 'd["data"]["folder"]')
check "db export → ok, Задачи.csv" "ok db-create && ok db-row && ok db-export && [[ -f \"$db_folder/Задачи.csv\" ]]"

# Импорт фикстуры Notion (вложенный ZIP, как у большой выгрузки) в «Проекты»; ход — строками в stderr (--human).
fixture=Packages/MyNotionKit/Tests/NotionImportTests/Fixtures/notion-export/synthetic-nested.zip
mn import notion $fixture --parent Проекты > $out/import.json 2> $out/import.err
check "import notion → ok, отчёт со страницами" "ok import && (( \$(py $out/import.json 'd[\"data\"][\"report\"][\"pageCount\"]') > 0 ))"
import_root=$(py $out/import.json 'd["data"]["report"]["rootPageId"]')
check "import --parent: ветка внутри «Проекты»" "[[ \$(py $out/import.json 'd[\"data\"][\"page\"][\"path\"][0]') == Проекты ]]"
mn --human import notion $fixture > $out/import-human.txt 2> $out/import-human.err
check "import --human: ход строками (чтение и запись) и итог" \
  "grep -q -- '— reading' $out/import-human.err && grep -q -- '— writing' $out/import-human.err && grep -q '✓ Импорт' $out/import-human.txt"
check "повтор той же выгрузки — previousImport в ответе" "mn import notion $fixture > $out/import-again.json 2>&1; [[ \$(py $out/import-again.json 'd[\"data\"][\"previousImport\"] is not None') == True ]]"
run import-missing import notion $out/нет.zip
check "импорт несуществующего файла → file_not_found" "[[ \$(py $out/import-missing.json 'd[\"error\"][\"code\"]') == file_not_found ]]"
run status app status
check "после импорта: app status — importing false" "[[ \$(py $out/status.json 'd[\"data\"][\"importing\"]') == False ]]"

# Снимок окна: ветка импорта в «Проекты», карточки хода и окна итога нет.
mn open $import_root > /dev/null 2>&1
sleep 1
~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$out/import-window.png\"}" > $out/import-window.json 2>&1
check "снимок окна с веткой импорта" "[[ -s $out/import-window.png ]]"

# Синхронизация: на этой базе она не включена — состояние off, `sync now` — понятная ошибка, код 4.
run sync-status sync status
check "sync status → enabled false, status off" \
  "ok sync-status && [[ \$(py $out/sync-status.json 'd[\"data\"][\"enabled\"]') == False && \$(py $out/sync-status.json 'd[\"data\"][\"status\"]') == off ]]"
run sync-now sync now
check "sync now без синхронизации → sync_disabled, код 4" \
  "[[ \$(py $out/sync-now.json 'd[\"error\"][\"code\"]') == sync_disabled && \$(cat $out/sync-now.rc) == 4 ]]"

pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion")
kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
rm -rf $dbdir

(( failed )) && note "ИТОГ импорта и выгрузки: есть провалы" || note "ИТОГ импорта и выгрузки: всё прошло"
exit $failed
