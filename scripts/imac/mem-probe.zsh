#!/bin/zsh
# На iMac внутри `imac-run --gui`: разбор роста кучи при фоновом запуске (`open -g`). Замер вкладок запускается
# обычным (fg) и фоновым (bg) запуском; в конце процесс ждёт (MYNOTION_BENCH_HOLD), и с него снимаются heap, vmmap, leaks.
#   mem-probe.zsh [fg] [bg] [bg-event] — без аргументов fg bg; bg-event — фоновый с пустым событием после каждого
#   перехода (MYNOTION_BENCH_POST_EVENT); MEM_PROBE_MSL=1 — с журналом стеков malloc. Граф памяти — app.memgraph.
#   mem-probe.zsh hide|mini|cover — обычный запуск человеком, окно на экране, потом ⌘H, свёрнуто в Dock или закрыто
#   другим окном (TextEdit на весь экран) на MEM_PROBE_AWAY секунд (по умолчанию 240): куча раз в минуту, состояние
#   окна по WindowServer до и после.
set -uo pipefail
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/mem-probe
dd=build/imac-uitest-dd-release
rm -rf $out; mkdir -p $out
modes=($@)
(( $# )) || modes=(fg bg)
reference=$TMPDIR/MyNotion-reference-library-v5/MyNotion.sqlite
if [[ ! -f $reference ]]; then
  # Эталон создаёт тест бюджета вкладок; он же даёт цифры кучи под XCTest для сравнения.
  zsh scripts/imac/on-imac.sh uitest --release -only-testing:PerformanceTests/TabsPerformanceTests > $out/xctest.log 2>&1
  grep -E "Память|Переключение" $out/xctest.log
else
  xcodegen generate -q
  xcodebuild -scheme MyNotionPerformance -configuration Release -derivedDataPath $dd -jobs $JOBS build-for-testing -quiet > $out/build.log 2>&1 || { tail -20 $out/build.log; exit 1 }
fi
app=$WORK/$dd/Build/Products/Release/MyNotion.app
[[ -f $reference ]] || { print "нет эталона" >&2; exit 1 }

heap_mb() { heap -s $1 2>/dev/null | grep -Eo 'All zones: [0-9]+ nodes \([0-9]+ bytes' | grep -Eo '[0-9]+ bytes' | awk '{printf "%.1f", $1/1048576}' }
cua() { ~/.local/bin/cua-driver call $1 $2 2>&1 }
# Пункт меню главного окна через Универсальный доступ — как выбор человеком; варианты подписей — русская и английская.
menu() {
  local pid=$1 window result item
  window=$(cua list_windows "{\"pid\":$pid}" | python3 -c 'import json,sys; print(max(json.load(sys.stdin)["windows"], key=lambda w: w["bounds"]["width"]*w["bounds"]["height"])["window_id"])')
  for item in ${@:2}; do
    result=$(cua invoke_menu "{\"pid\":$pid,\"window_id\":$window,\"path\":$item}")
    print "  меню $item: ${${result//$'\n'/ }[1,300]}"
    [[ $result == *rror* || $result == *ailed* || $result == *refus* ]] || return 0
  done
  print "  меню не сработало: $result"
}
# Окно MyNotion по WindowServer: на экране ли, место в стопке и окно поверх него (TextEdit в сценарии cover).
window_state() {
  cua list_windows '{}' | python3 -c '
import json, sys
pid, cover = int(sys.argv[1]), int(sys.argv[2])
ws = json.load(sys.stdin)["windows"]
own = [w for w in ws if w["pid"] == pid]
top = [w for w in ws if w["pid"] == cover]
for w in own: print("  окно MyNotion: на экране", w["is_on_screen"], "z", w["z_index"], "рамка", w["bounds"])
for w in top: print("  окно поверх:", w["app_name"], "на экране", w["is_on_screen"], "z", w["z_index"], "рамка", w["bounds"])
' $1 $2
}

for mode in $modes; do
  if [[ $mode == (hide|mini|cover) ]]; then
    dir=$out/$mode
    mkdir -p $dir
    cp -c $reference $dir/MyNotion.sqlite
    open -n $app --args --database $dir/MyNotion.sqlite
    sleep 15
    pid=$(pgrep -n -f "$dir/MyNotion.sqlite")
    [[ -n $pid ]] || { print "$mode: приложение не запустилось"; continue }
    cua bring_to_front "{\"pid\":$pid}" > /dev/null
    sleep 5
    print "$mode: на экране $(heap_mb $pid) МБ"
    case $mode in
      # Окнами управляет CuaDriver (у него права Универсального доступа); AppleEvents к Finder и System Events не слать.
      hide) menu $pid '["MyNotion","Скрыть MyNotion"]' '["MyNotion","Hide MyNotion"]' ;;
      mini)
        window=$(cua list_windows "{\"pid\":$pid}" | python3 -c 'import json,sys; print(max(json.load(sys.stdin)["windows"], key=lambda w: w["bounds"]["width"]*w["bounds"]["height"])["window_id"])')
        cua bring_to_front "{\"pid\":$pid}" > /dev/null; sleep 2
        print "  ⌘M: $(cua hotkey "{\"pid\":$pid,\"window_id\":$window,\"keys\":[\"cmd\",\"m\"]}" | tr '\n' ' ' | cut -c1-200)" ;;
      cover)
        print "окно, которое закроет MyNotion" > $dir/cover.txt
        open -n -a TextEdit $dir/cover.txt
        sleep 5
        cover_pid=$(pgrep -n -x TextEdit)
        cover_window=$(cua list_windows "{\"pid\":$cover_pid}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["windows"][0]["window_id"])')
        cua set_window_frame "{\"pid\":$cover_pid,\"window_id\":$cover_window,\"x\":0,\"y\":0,\"width\":2240,\"height\":1260}" > /dev/null
        cua bring_to_front "{\"pid\":$cover_pid}" > /dev/null ;;
    esac
    sleep 3
    window_state $pid ${cover_pid:-0}
    for minute in {1..$(( ${MEM_PROBE_AWAY:-240} / 60 ))}; do
      sleep 60
      print "$mode: ${minute} мин вне экрана $(heap_mb $pid) МБ"
    done
    window_state $pid ${cover_pid:-0}
    [[ $mode == cover ]] && { kill $cover_pid; cover_pid= }
    cua bring_to_front "{\"pid\":$pid}" > /dev/null
    sleep 8
    print "$mode: в конце, после вывода вперёд $(heap_mb $pid) МБ"
    kill $pid; sleep 2
    continue
  fi
  dir=$out/$mode
  mkdir -p $dir
  cp -c $reference $dir/MyNotion.sqlite
  flags=(-n)
  [[ $mode == bg* ]] && flags+=(-g)
  envs=(--env MYNOTION_BENCH_HOLD=$dir/hold)
  [[ ${MEM_PROBE_MSL:-0} == 1 ]] && envs+=(--env MallocStackLogging=1)
  [[ $mode == *event ]] && envs+=(--env MYNOTION_BENCH_POST_EVENT=1)
  ioreg -n Root -d1 | grep -o '"CGSSessionScreenIsLocked"=[A-Za-z]*' > $dir/screen-before.txt
  open $flags $envs $app --args --database $dir/MyNotion.sqlite --tabs-benchmark $dir/report.json
  for _ in {1..600}; do [[ -f $dir/hold ]] && break; sleep 1; done
  ioreg -n Root -d1 | grep -o '"CGSSessionScreenIsLocked"=[A-Za-z]*' > $dir/screen-after.txt
  pid=$(cat $dir/hold 2>/dev/null)
  if [[ -n $pid ]]; then
    heap -s $pid > $dir/heap.txt 2>&1
    vmmap -summary $pid > $dir/vmmap.txt 2>&1
    leaks $pid > $dir/leaks.txt 2>&1
    # Граф памяти — для разбора, кто держит удержанное (heap --addresses, leaks --traceTree по файлу).
    leaks --outputGraph=$dir/app.memgraph $pid > /dev/null 2>&1
    # Окно впереди: освобождается ли удержанное, когда приложение становится активным и рисует.
    cua bring_to_front "{\"pid\":$pid}" > $dir/activate.txt
    sleep 8
    heap -s $pid > $dir/heap-active.txt 2>&1
    grep -E "^(All zones|Process).*nodes" $dir/heap-active.txt | head -2
    kill $pid
  fi
  sleep 2
  python3 - $dir/report.json $mode <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(sys.argv[2], "куча 1 вкладка", round(r.get("heapOneTabMB") or 0, 1), "→ 20 вкладок", round(r.get("heapTwentyTabsMB") or 0, 1),
      "| след", round(r.get("memoryOneTabMB") or 0, 1), "→", round(r.get("memoryTwentyTabsMB") or 0, 1), "| ошибка", r.get("error"))
PY
  cat $dir/screen-before.txt $dir/screen-after.txt | tr '\n' ' '; print
  grep -m1 -E "^Process|leaks for" $dir/leaks.txt
  grep -A3 -E "^All zones|^Process .*: [0-9]+ nodes" $dir/heap.txt | head -4
  sed -n '/^Sorted by size/,+22p' $dir/heap.txt | head -24
done
