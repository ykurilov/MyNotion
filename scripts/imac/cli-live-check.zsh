#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): живая проверка команды `mynotion` на Release (005, T026).
#   1. установка `scripts/install-cli.sh` в папки сборки (HOME подменён: домашняя папка iMac не меняется);
#   2. приложение закрыто → `mynotion app status` поднимает его в фоне: фокус не уходит, ответ ≤ 4 с;
#   3. `mynotion page tree` → `not_implemented` (код выхода 4); права сокета 0600;
#   4. память и процессор в покое с открытым сокетом против сборки 004 (CLI_BASE — папка исходников 004 на iMac).
#   5. блоки и обложка (этап 3, шаги 5–6 сценария A): правка командой видна в окне ≤ 1 с, курсор в другом блоке на месте,
#      снимки экрана build/cli-live/blocks-*.png. CLI_LIVE_ONLY=blocks — только этот шаг (после установки).
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

live_blocks

(( failed )) && note "ИТОГ: есть провалы" || note "ИТОГ: всё прошло"
exit $failed
