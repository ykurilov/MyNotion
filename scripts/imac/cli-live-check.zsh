#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка команды `mynotion` на Release (005, T026, T036).
#   1. установка `scripts/install-cli.sh` в папки сборки (HOME подменён: домашняя папка iMac не меняется);
#   2. приложение закрыто → `mynotion page tree --depth 1` поднимает его в фоне: фокус не уходит, ответ ≤ 4 с (сценарий A, шаг 1);
#   3. страницы (шаги 2, 3, 11): `page create` с `meeting.md`, `page read` — тот же Markdown, корзина, `trash delete` без
#      `--force` → `force_required`; снимок окна; права сокета 0600;
#   4. память и процессор в покое с открытым сокетом против прошлой сборки (CLI_BASE — папка её исходников на iMac, CLI_BASE_LABEL — подпись, по умолчанию 004).
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

(( failed )) && note "ИТОГ: есть провалы" || note "ИТОГ: всё прошло"
exit $failed
