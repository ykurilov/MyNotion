#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка команды `mynotion` на Release (005, T026).
#   1. установка `scripts/install-cli.sh` в папки сборки (HOME подменён: домашняя папка iMac не меняется);
#   2. приложение закрыто → `mynotion app status` поднимает его в фоне: фокус не уходит, ответ ≤ 4 с;
#   3. `mynotion page tree` → `not_implemented` (код выхода 4); права сокета 0600;
#   4. память и процессор в покое с открытым сокетом против сборки 004 (CLI_BASE — папка исходников 004 на iMac).
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

(( failed )) && note "ИТОГ: есть провалы" || note "ИТОГ: всё прошло"
exit $failed
